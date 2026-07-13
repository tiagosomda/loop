import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import '../models/models.dart';

enum BoardView { list, kanban }

const _statusFilterPrefsKey = 'statusFilter';

class AppState extends ChangeNotifier {
  AppState() {
    _restoreTheme();
    _restoreStatusFilter();
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
  // When true the board shows only archived items; otherwise archived items
  // are hidden from the default view.
  bool showArchived = false;

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

  Future<void> _restoreStatusFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_statusFilterPrefsKey);
    if (saved == null) return;
    statusFilter
      ..clear()
      ..addAll(saved.where(itemStatuses.contains));
    notifyListeners();
  }

  void toggleStatusFilter(String status) {
    statusFilter.contains(status)
        ? statusFilter.remove(status)
        : statusFilter.add(status);
    notifyListeners();
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setStringList(_statusFilterPrefsKey, statusFilter.toList()),
    );
  }

  void toggleShowArchived() {
    showArchived = !showArchived;
    notifyListeners();
  }

  void setRepoFilter(String? repoId) {
    repoFilter = repoId;
    notifyListeners();
  }

  Future<void> signIn() async {
    final provider = GoogleAuthProvider();
    await FirebaseAuth.instance.signInWithPopup(provider);
  }

  Future<void> signOut() => FirebaseAuth.instance.signOut();
}
