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
