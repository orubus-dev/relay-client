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
        // The web login page hands the session back via relay://login#… (a
        // custom scheme a WebView cannot navigate to — it used to surface as
        // ERR_UNKNOWN_URL_SCHEME / "a format the WebView can't understand").
        // Intercept it here instead: parse the tokens and capture the session
        // without any navigation.
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final url = navigationAction.request.url.toString();
          if (url.startsWith('relay://')) {
            _handleRelaySchemeUrl(url);
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
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

  /// relay://login#access_token=…&refresh_token=… (also tolerates ?query form
  /// and relay://auth). Extracts the Supabase tokens and completes sign-in.
  Future<void> _handleRelaySchemeUrl(String url) async {
    try {
      final uri = Uri.parse(url.replaceFirst('relay://', 'https://relay.invalid/'));
      final params = <String, String>{
        ...uri.queryParameters,
        if (uri.fragment.isNotEmpty) ...Uri.splitQueryString(uri.fragment),
      };
      final access = params['access_token'];
      final refresh = params['refresh_token'];
      if (access == null || refresh == null || access.isEmpty) return;
      final sessionJson = jsonEncode({'access_token': access, 'refresh_token': refresh});
      await _handleSessionJson(sessionJson);
    } catch (_) {
      // malformed handoff — the localStorage bridge remains the fallback
    }
  }
}
