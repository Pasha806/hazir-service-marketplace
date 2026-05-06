## Introduction

Hazir is a cross-platform mobile application developed using Flutter and Firebase, designed to streamline how users book everyday services such as home repairs, pick & drop, and on-site assistance with AI Recommendation System. The app connects seekers and service providers in real time, offering a modern, map-based workflow similar to ride-hailing platforms.

The system implements core service marketplace functionality including provider onboarding, service listings, live request creation, real-time location tracking, in-app messaging, and order history management. All interactions are powered by Firebase Authentication, Cloud Firestore, Firebase Storage, and Google Maps SDK, ensuring a fast, secure, and scalable experience without the need for a traditional backend server.

Developing Hazir strengthened my understanding of state management, real-time databases, geolocation, responsive UI design, and event-driven architecture. It also gave hands-on experience with integrating maps, handling asynchronous data streams, and designing role-based user flows for different types of users.

## Key Features

User registration & role-based login (Seeker / Provider)
Provider onboarding with service listing management
Service browsing, search, and detail viewing
Live service request creation with real-time status updates
Uber-style real-time location tracking between seeker and provider
In-app chat for communication during active jobs
Order / service history for both user roles
Profile management with image upload
Status workflows: Waiting → Ongoing → Completed / Cancelled

## Technologies Used

Flutter (Dart) – Cross-platform mobile development
Firebase Authentication – Secure login system
Cloud Firestore – Real-time database for users, listings, and bookings
Firebase Storage – Image uploads (profile & listing photos)
Google Maps SDK – Live tracking, map markers, and routing
Geolocator API – GPS location access
Provider / setState – State management