import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/logged_out_screen.dart';
import 'services/board_service.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: firebaseOptions);
  runApp(const DevLoopApp());
}

class DevLoopApp extends StatelessWidget {
  const DevLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider(create: (_) => BoardService()),
      ],
      child: Consumer<AppState>(
        builder: (context, app, _) => MaterialApp(
          title: 'dev loop',
          debugShowCheckedModeBanner: false,
          themeMode: app.themeMode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: app.signedIn && app.authorized
              ? const HomeScreen()
              : const LoggedOutScreen(),
        ),
      ),
    );
  }
}

/// Theme cycle button used on every header (system -> dark -> light).
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final icon = switch (app.themeMode) {
      ThemeMode.system => Icons.brightness_auto,
      ThemeMode.dark => Icons.dark_mode,
      ThemeMode.light => Icons.light_mode,
    };
    return IconButton(
      tooltip: 'Theme: ${app.themeMode.name}',
      icon: Icon(icon),
      onPressed: app.cycleTheme,
    );
  }
}
