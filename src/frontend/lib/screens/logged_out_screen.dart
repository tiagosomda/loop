import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../state/app_state.dart';
import '../widgets/brand_logo.dart';

class LoggedOutScreen extends StatelessWidget {
  const LoggedOutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final wrongAccount = app.signedIn && !app.authorized;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const BrandTitle(showLogo: false),
        actions: [
          const ThemeToggleButton(),
          IconButton(
            tooltip: wrongAccount ? 'Sign out' : 'Sign in',
            icon: Icon(wrongAccount ? Icons.logout : Icons.login),
            onPressed: () => wrongAccount ? app.signOut() : app.signIn(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SpinningDevLoopLogo(size: 220, tappable: true),
                const SizedBox(height: 24),
                Text(
                  wrongAccount
                      ? 'This account is not authorized for the board.'
                      : "This is tiago's dev loop experiment — a board of "
                            'action items that an AI agent picks up and works '
                            'on, on a schedule.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('notes.tiago.dev'),
                  onPressed: () =>
                      launchUrl(Uri.parse('https://notes.tiago.dev')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
