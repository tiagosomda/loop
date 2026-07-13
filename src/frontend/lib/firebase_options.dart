import 'package:firebase_core/firebase_core.dart';

/// Web config for the shared `tiago-dev-site` Firebase project.
/// Public by design; access control lives in the security rules.
const firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyAOJCxd1PY7JcsIc2z1KtCVZcDst4CtnFM',
  authDomain: 'tiago-dev-site.firebaseapp.com',
  projectId: 'tiago-dev-site',
  storageBucket: 'tiago-dev-site.firebasestorage.app',
  messagingSenderId: '706177559293',
  appId: '1:706177559293:web:1f0f63a1f288a553d7ac94',
  measurementId: 'G-G5R5L08ZNY',
);

/// The only account the security rules authorize.
const authorizedEmail = 'tsomda@gmail.com';
