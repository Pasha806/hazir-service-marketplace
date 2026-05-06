import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'chat_screen.dart';

const Color _accent = Color(0xFF7966FA);
const Color _bgHeader = Color(0xFF7966FA);
const Color _bgMain = Color(0xFFF8F9FD);
const Color _text = Color(0xFF1B1C20);
const Color _sub = Color(0xFF8D91A1);
const Color _whatsAppGreen = Color(0xFF25D366);

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  static void openChat(BuildContext context, {required String myUid, required String otherUid, required String otherName, String? otherAvatar}) {
    final String chatId = (myUid.compareTo(otherUid) > 0)
        ? '${myUid}_$otherUid'
        : '${otherUid}_$myUid';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatId: chatId,
          otherUserId: otherUid,
          otherUserName: otherName,
          otherUserAvatar: otherAvatar,
        ),
      ),
    );
  }

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchText = "";

  String _fmtTime(DateTime? d) {
    if (d == null) return '';
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inDays == 0) return DateFormat('h:mm a').format(d);
    if (diff.inDays < 7) return DateFormat('EEE').format(d);
    return DateFormat('d MMM').format(d);
  }

  Future<void> _deleteChat(String docId) async {
    await FirebaseFirestore.instance.collection('chats').doc(docId).delete();
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return const Scaffold(body: Center(child: Text("Log in")));

    return Scaffold(
      backgroundColor: _bgMain,
      body: Column(
        children: [
          // --- HEADER ---
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 20,
              left: 20,
              right: 20,
              bottom: 24,
            ),
            decoration: const BoxDecoration(
              color: _bgHeader,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Messages',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 16),
                // Search Bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: _sub),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (val) => setState(() => _searchText = val.trim().toLowerCase()),
                          style: const TextStyle(color: _text, fontSize: 15, fontWeight: FontWeight.w500),
                          decoration: const InputDecoration(
                            hintText: 'Search chats...',
                            hintStyle: TextStyle(color: _sub, fontSize: 15),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      if (_searchText.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close, size: 20, color: _sub),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchText = "");
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // --- CHAT LIST ---
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .where('users', arrayContains: myUid)
                  .orderBy('lastMessageTime', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data?.docs ?? [];

                // Filter locally for search
                final filteredDocs = docs.where((doc) {
                  if (_searchText.isEmpty) return true;
                  final data = doc.data() as Map<String, dynamic>;
                  // Basic check on serialized data, refinement happens in Tile
                  return data.toString().toLowerCase().contains(_searchText);
                }).toList();

                if (filteredDocs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey.shade300),
                        const SizedBox(height: 10),
                        Text(
                          _searchText.isEmpty ? 'No messages yet' : 'No chats found',
                          style: TextStyle(color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                  itemCount: filteredDocs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final doc = filteredDocs[index];
                    return _ChatTileLoader(
                      doc: doc,
                      myUid: myUid,
                      onDelete: () => _deleteChat(doc.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- SMART TILE LOADER (Fixes "User" name issue) ---
class _ChatTileLoader extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final String myUid;
  final VoidCallback onDelete;

  const _ChatTileLoader({
    required this.doc,
    required this.myUid,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final users = List<String>.from(data['users'] ?? []);
    final otherUid = users.firstWhere((id) => id != myUid, orElse: () => '');

    // Get basic meta
    final meta = data['meta'] as Map<String, dynamic>? ?? {};
    final otherMeta = meta[otherUid] as Map<String, dynamic>? ?? {};

    String displayName = otherMeta['name'] as String? ?? 'User';
    final avatar = otherMeta['avatar'] as String?;

    // --- FALLBACK LOGIC ---
    // If name is "User", fetch real profile from 'users' collection
    if (displayName == 'User' || displayName.isEmpty) {
      return FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(otherUid).get(),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            final userData = snapshot.data!.data() as Map<String, dynamic>? ?? {};

            // Try to find name in standard locations
            final pName = userData['provider']?['name'];
            final uName = userData['profile']?['name'];
            final baseName = userData['name'];

            final realName = pName ?? uName ?? baseName ?? 'User';

            return _buildTile(context, data, realName, avatar, otherUid);
          }
          // While loading, show placeholder
          return _buildTile(context, data, 'Loading...', avatar, otherUid);
        },
      );
    }

    return _buildTile(context, data, displayName, avatar, otherUid);
  }

  Widget _buildTile(BuildContext context, Map<String, dynamic> data, String name, String? avatar, String otherUid) {
    final lastMsg = data['lastMessage'] ?? '';
    final time = (data['lastMessageTime'] as Timestamp?)?.toDate();

    // Unread Count Logic - Robust Cast
    final unreadMap = data['unreadCount'] as Map<String, dynamic>? ?? {};
    final rawCount = unreadMap[myUid];
    int unreadCount = 0;
    if (rawCount is int) unreadCount = rawCount;
    else if (rawCount is double) unreadCount = rawCount.toInt();

    // Time formatter
    String timeStr = '';
    if (time != null) {
      final now = DateTime.now();
      final diff = now.difference(time);
      if (diff.inDays == 0) timeStr = DateFormat('h:mm a').format(time);
      else if (diff.inDays < 7) timeStr = DateFormat('EEE').format(time);
      else timeStr = DateFormat('d MMM').format(time);
    }

    return Dismissible(
      key: Key(doc.id),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          color: Colors.redAccent,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline, color: Colors.white),
            Text("Delete", style: TextStyle(color: Colors.white, fontSize: 12))
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        return await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Delete Conversation?"),
            content: const Text("This cannot be undone."),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Cancel")),
              TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
            ],
          ),
        );
      },
      onDismissed: (_) => onDelete(),
      child: _ChatListCard(
        name: name,
        message: lastMsg,
        time: timeStr,
        avatar: avatar,
        unreadCount: unreadCount,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                chatId: doc.id,
                otherUserId: otherUid,
                otherUserName: name,
                otherUserAvatar: avatar,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ChatListCard extends StatelessWidget {
  final String name;
  final String message;
  final String time;
  final String? avatar;
  final int unreadCount;
  final VoidCallback onTap;

  const _ChatListCard({
    required this.name,
    required this.message,
    required this.time,
    this.avatar,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasUnread = unreadCount > 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade100),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 8,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            children: [
              // AVATAR
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F2FB),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // TEXT
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w600,
                              color: _text,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 12,
                            color: hasUnread ? _whatsAppGreen : _sub,
                            fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            message,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: hasUnread ? Colors.black87 : _sub,
                              fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (hasUnread)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            width: 24,
                            height: 24,
                            decoration: const BoxDecoration(
                              color: _whatsAppGreen,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                unreadCount > 99 ? '99+' : '$unreadCount',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}