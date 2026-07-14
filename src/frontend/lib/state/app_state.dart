import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import '../models/models.dart';

enum BoardView { list, kanban, projects }

const _statusFilterPrefsKey = 'statusFilter';
const _statusFilterVersionPrefsKey = 'statusFilterVersion';
const _statusFilterVersion = 2;

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
  // Selected statuses are represented literally: all selected means show all,
  // while an empty set means show no items. Seed the first launch with every
  // status so the default board remains the complete board.
  final Set<String> statusFilter = itemStatuses.toSet();
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
    final version = prefs.getInt(_statusFilterVersionPrefsKey);
    statusFilter
      ..clear()
      // Before literal empty-filter semantics, an empty saved set still meant
      // "show all." Migrate that one legacy value without preventing users
      // from saving an intentionally empty selection from now on.
      ..addAll(
        version == _statusFilterVersion || saved.isNotEmpty
            ? saved.where(itemStatuses.contains)
            : itemStatuses,
      );
    notifyListeners();
    await prefs.setInt(_statusFilterVersionPrefsKey, _statusFilterVersion);
  }

  void toggleStatusFilter(String status) {
    statusFilter.contains(status)
        ? statusFilter.remove(status)
        : statusFilter.add(status);
    notifyListeners();
    _saveStatusFilter();
  }

  void setAllStatusesSelected(bool selected) {
    statusFilter
      ..clear()
      ..addAll(selected ? itemStatuses : const <String>[]);
    notifyListeners();
    _saveStatusFilter();
  }

  Future<void> _saveStatusFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_statusFilterPrefsKey, statusFilter.toList());
    await prefs.setInt(_statusFilterVersionPrefsKey, _statusFilterVersion);
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
