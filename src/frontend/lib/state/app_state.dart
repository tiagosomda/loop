import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';

enum BoardView { list, kanban }

class AppState extends ChangeNotifier {
  AppState() {
    _restoreTheme();
    FirebaseAuth.instance.authStateChanges().listen((u) {
      user = u;
      notifyListeners();
    });
  }

  User? user;
  ThemeMode themeMode = ThemeMode.system;
  BoardView boardView = BoardView.list;

  // board filters
  String search = '';
  final Set<String> statusFilter = {};
  String? repoFilter;
  String sortBy = 'updated'; // updated | created | title

  bool get signedIn => user != null;
  bool get authorized => user?.email == authorizedEmail;

  Future<void> _restoreTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('themeMode');
    if (saved != null) {
      themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => ThemeMode.system,
      );
      notifyListeners();
    }
  }

  Future<void> cycleTheme() async {
    const order = [ThemeMode.system, ThemeMode.dark, ThemeMode.light];
    themeMode = order[(order.indexOf(themeMode) + 1) % order.length];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', themeMode.name);
  }

  void setBoardView(BoardView view) {
    boardView = view;
    notifyListeners();
  }

  void cycleBoardView() {
    final values = BoardView.values;
    boardView = values[(boardView.index + 1) % values.length];
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  void toggleStatusFilter(String status) {
    statusFilter.contains(status)
        ? statusFilter.remove(status)
        : statusFilter.add(status);
    notifyListeners();
  }

  void setRepoFilter(String? repoId) {
    repoFilter = repoId;
    notifyListeners();
  }

  void setSortBy(String value) {
    sortBy = value;
    notifyListeners();
  }

  Future<void> signIn() async {
    final provider = GoogleAuthProvider();
    await FirebaseAuth.instance.signInWithPopup(provider);
  }

  Future<void> signOut() => FirebaseAuth.instance.signOut();
}
