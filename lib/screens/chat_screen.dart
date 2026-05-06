import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

const Color _accent = Color(0xFF7966FA);
const Color _myBubble = Color(0xFF7966FA);
const Color _otherBubble = Color(0xFFF2F4F7);
const Color _text = Color(0xFF1B1C20);
const Color _selectionOverlay = Color(0x337966FA);

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String otherUserId;
  final String otherUserName;
  final String? otherUserAvatar;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.otherUserId,
    required this.otherUserName,
    this.otherUserAvatar,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  bool _isUploading = false;
  String? _myRealName;

  // --- MULTI-SELECT STATE ---
  final Map<String, String> _selectedMessages = {};
  bool get _isSelectionMode => _selectedMessages.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _resetUnreadCount();
    _fetchMyName();
  }

  Future<void> _fetchMyName() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        setState(() {
          _myRealName = data['provider']?['name'] ??
              data['profile']?['name'] ??
              data['name'] ??
              data['displayName'];
        });
      }
    } catch (_) {}
  }

  void _resetUnreadCount() {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;
    FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
      'unreadCount.$myUid': 0,
    }).catchError((_) {});
  }

  // --- SELECTION LOGIC ---
  void _toggleSelection(String docId, String senderId) {
    setState(() {
      if (_selectedMessages.containsKey(docId)) {
        _selectedMessages.remove(docId);
      } else {
        _selectedMessages[docId] = senderId;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedMessages.clear();
    });
  }

  // --- DELETE LOGIC ---
  Future<void> _handleDeletePress() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null || _selectedMessages.isEmpty) return;

    final bool containsOthersMessages = _selectedMessages.values.any((id) => id != myUid);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Delete ${_selectedMessages.length} messages?"),
        content: const Text("Select delete option."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          if (!containsOthersMessages)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _performBatchDelete(deleteForEveryone: true);
              },
              child: const Text("Delete for Everyone", style: TextStyle(color: Colors.red)),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _performBatchDelete(deleteForEveryone: false);
            },
            child: const Text("Delete for Me", style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _performBatchDelete({required bool deleteForEveryone}) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    final batch = FirebaseFirestore.instance.batch();

    // Calculate new Last Message Text if needed
    // (Optimization: In a real app, you'd calculate what the previous message is to update 'lastMessage')
    // For now, we just update the specific message documents.

    for (String docId in _selectedMessages.keys) {
      final ref = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .doc(docId);

      if (deleteForEveryone) {
        batch.update(ref, {
          'type': 'deleted',
          'text': 'This message was deleted', // Clean text for preview
          'attachmentBase64': null,
        });
      } else {
        batch.update(ref, {
          'hiddenBy': FieldValue.arrayUnion([myUid])
        });
      }
    }

    await batch.commit();
    _clearSelection();
  }

  Future<void> _deleteMessage(String docId, bool isMe, bool forEveryone) async {
    // Single message delete (Legacy support for long press single item)
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    if (forEveryone && isMe) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .doc(docId)
          .update({
        'type': 'deleted',
        'text': 'This message was deleted',
        'attachmentBase64': null,
      });
    } else {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .doc(docId)
          .update({
        'hiddenBy': FieldValue.arrayUnion([myUid])
      });
    }
  }

  void _showDeleteOptions(BuildContext context, String docId, bool isMe, String type) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete for me'),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMessage(docId, isMe, false);
                },
              ),
              if (isMe && type != 'deleted')
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.red),
                  title: const Text('Delete for everyone'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteMessage(docId, isMe, true);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // --- SENDING ---
  Future<void> _sendImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 40, maxWidth: 600);
    if (image == null) return;

    setState(() => _isUploading = true);
    try {
      final bytes = await File(image.path).readAsBytes();
      final String base64Image = base64Encode(bytes);
      _sendMessage(text: '胴 Image', type: 'image', attachmentBase64: base64Image);
    } catch (e) {
      // ignore
    } finally {
      setState(() => _isUploading = false);
    }
  }

  void _sendVoiceStub() {
    _sendMessage(text: '痔 Voice Message', type: 'audio');
  }

  void _sendMessage({required String text, String type = 'text', String? attachmentBase64}) async {
    if (type == 'text' && text.trim().isEmpty) return;
    _msgController.clear();

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = FieldValue.serverTimestamp();

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .add({
      'senderId': user.uid,
      'text': text,
      'type': type,
      'attachmentBase64': attachmentBase64,
      'createdAt': now,
      'read': false,
      'hiddenBy': [],
    });

    final myDisplayName = _myRealName ?? user.displayName ?? 'User';

    final Map<String, dynamic> updateData = {
      'lastMessage': type == 'image' ? '胴 Image' : (type == 'audio' ? '痔 Voice' : text),
      'lastMessageTime': now,
      'users': [user.uid, widget.otherUserId],
      'unreadCount.${widget.otherUserId}': FieldValue.increment(1),
      'meta.${user.uid}.name': myDisplayName,
      'meta.${widget.otherUserId}.name': widget.otherUserName,
    };

    if (widget.otherUserAvatar != null) {
      updateData['meta.${widget.otherUserId}.avatar'] = widget.otherUserAvatar;
    }

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .set(updateData, SetOptions(merge: true));

    if (_scrollController.hasClients) {
      _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  // --- APP BAR BUILDER ---
  PreferredSizeWidget _buildAppBar() {
    if (_isSelectionMode) {
      return AppBar(
        backgroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close, color: _text),
          onPressed: _clearSelection,
        ),
        title: Text(
          "${_selectedMessages.length} Selected",
          style: const TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: _handleDeletePress,
          ),
        ],
      );
    }

    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0.5,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _text),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xFFF1F2FB),
            child: Text(
              widget.otherUserName.isNotEmpty ? widget.otherUserName[0].toUpperCase() : '?',
              style: const TextStyle(color: _accent, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.otherUserName,
              style: const TextStyle(color: _text, fontWeight: FontWeight.w800, fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.phone_rounded, color: _accent),
          onPressed: _callUser,
        ),
      ],
    );
  }

  Future<void> _callUser() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(widget.otherUserId).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        String? phone = data['phone'] ?? data['provider']?['phone'];
        if (phone != null && phone.isNotEmpty) {
          final uri = Uri(scheme: 'tel', path: phone);
          if (await canLaunchUrl(uri)) await launchUrl(uri);
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(widget.chatId)
                  .collection('messages')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snapshot.data!.docs;

                if (docs.isEmpty) {
                  return const Center(child: Text("Say Hello! 窓", style: TextStyle(color: Colors.grey)));
                }

                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;

                    // Hide messages deleted for me
                    final hiddenBy = List<String>.from(data['hiddenBy'] ?? []);
                    if (hiddenBy.contains(myUid)) return const SizedBox.shrink();

                    final isMe = data['senderId'] == myUid;
                    final time = (data['createdAt'] as Timestamp?)?.toDate();
                    final timeStr = time != null ? DateFormat('h:mm a').format(time) : '...';
                    final type = data['type'] ?? 'text';
                    final b64 = data['attachmentBase64'];
                    final txt = data['text'] ?? '';

                    final bool isSelected = _selectedMessages.containsKey(doc.id);

                    // --- CONTENT BUILDER ---
                    Widget content;

                    if (type == 'deleted') {
                      // WHATSAPP STYLE DELETED MESSAGE
                      content = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                              Icons.block,
                              color: isMe ? Colors.white.withOpacity(0.5) : Colors.grey[500],
                              size: 16
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'This message was deleted',
                            style: TextStyle(
                              color: isMe ? Colors.white.withOpacity(0.6) : Colors.grey[600],
                              fontStyle: FontStyle.italic,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      );
                    } else if (type == 'image' && b64 != null) {
                      content = ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.memory(
                          base64Decode(b64),
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, err, _) => const Icon(Icons.broken_image, color: Colors.white),
                        ),
                      );
                    } else if (type == 'audio') {
                      content = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.mic_rounded, color: isMe ? Colors.white : _text),
                          const SizedBox(width: 8),
                          Text('Voice Message', style: TextStyle(color: isMe ? Colors.white : _text)),
                        ],
                      );
                    } else {
                      content = Text(
                        txt,
                        style: TextStyle(
                          color: isMe ? Colors.white : _text,
                          fontSize: 15,
                        ),
                      );
                    }

                    return GestureDetector(
                      onLongPress: () {
                        if (!_isSelectionMode) {
                          _toggleSelection(doc.id, data['senderId']);
                        }
                      },
                      onTap: () {
                        if (_isSelectionMode) {
                          _toggleSelection(doc.id, data['senderId']);
                        }
                      },
                      child: Container(
                        color: isSelected ? _selectionOverlay : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Align(
                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: type == 'image'
                                ? const EdgeInsets.all(4)
                                : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              color: isMe ? _myBubble : _otherBubble,
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(18),
                                topRight: const Radius.circular(18),
                                bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
                                bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
                              ),
                              border: isSelected ? Border.all(color: _accent, width: 2) : null,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                content, // Render the message content (Text, Image, or Deleted Icon)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, right: 4, bottom: 2),
                                  child: Text(
                                    timeStr,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isMe ? Colors.white.withOpacity(0.7) : Colors.grey[500],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_isUploading) const LinearProgressIndicator(minHeight: 2),

          if (!_isSelectionMode)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, -5))],
              ),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.add_photo_alternate_rounded, color: Colors.grey), onPressed: _sendImage),
                  IconButton(icon: const Icon(Icons.mic_rounded, color: Colors.grey), onPressed: _sendVoiceStub),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6F7FB),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFFE8E9EF)),
                      ),
                      child: TextField(
                        controller: _msgController,
                        textCapitalization: TextCapitalization.sentences,
                        minLines: 1,
                        maxLines: 4,
                        style: const TextStyle(color: _text),
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: TextStyle(color: Colors.grey),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _sendMessage(text: _msgController.text.trim()),
                    child: Container(
                      width: 48, height: 48,
                      decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}