import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/constants.dart';
import '../../data/auth/auth_repository.dart';

/// Sign in / sign up inside a WebView against the production web app.
/// Continue with Google just works — the OAuth flow runs on the web app,
/// no native SHA-1/consent-screen setup required. When the page reports an
/// authenticated Supabase session via the JS bridge, we capture it and
/// continue into the app.
class AuthWebViewScreen extends StatefulWidget {
  final AuthRepository auth;
  final void Function(Map<String, dynamic> profile) onAuthenticated;

  const AuthWebViewScreen({super.key, required this.auth, required this.onAuthenticated});

  @override
  State<AuthWebViewScreen> createState() => _AuthWebViewScreenState();
}

class _AuthWebViewScreenState extends State<AuthWebViewScreen> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    // register the session bridge
    InAppWebViewController.addJavaScriptHandler(
      handlerName: AuthRepository.jsHandlerName,
      callback: (args) async {
        if (args.isNotEmpty && args.first is String) {
          await _handleSessionJson(args.first as String);
        }
        return null;
      },
    );
  }

  Future<void> _handleSessionJson(String sessionJson) async {
    if (_capturing) return;
    _capturing = true;
    final profile = await widget.auth.captureSession(sessionJson);
    if (!mounted) return;
    if (profile != null) {
      widget.onAuthenticated(profile);
    } else {
      setState(() => _capturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign-in completed but session capture failed — try again')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to Relay'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(RelayConfig.authBaseUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: false,
          userAgent: 'RelayClient/1.0 (${RelayConfig.packageName})',
          supportZoom: false,
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: AuthRepository.jsHandlerName,
            callback: (args) async {
              if (args.isNotEmpty && args.first is String) {
                await _handleSessionJson(args.first as String);
              }
              return null;
            },
          );
        },
        onLoadStop: (controller, url) async {
          await controller.evaluateJavascript(source: widget.auth.bridgeScript);
          // double-check directly (bridge interval may lag on slow loads)
          final raw = await controller.evaluateJavascript(
            source: "localStorage.getItem('sb-gobwknacvpgysmgpvzqt-auth-token')",
          );
          if (raw is String && raw.isNotEmpty) {
            final decoded = raw.startsWith('"') ? jsonDecode(raw) as String : raw;
            if (decoded.contains('access_token')) await _handleSessionJson(decoded);
          }
        },
        onProgressChanged: (controller, progress) => setState(() => _progress = progress / 100),
      ),
    );
  }
}
