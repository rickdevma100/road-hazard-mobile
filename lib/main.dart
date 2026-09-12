import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'features/contributor/session_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const RoadHazardApp());
}

class RoadHazardApp extends StatelessWidget {
  const RoadHazardApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'Roadwatch Contributor', debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC0F27B), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF111814)),
    home: const ContributorScreen());
}

class ContributorScreen extends StatefulWidget {
  const ContributorScreen({super.key});
  @override State<ContributorScreen> createState() => _ContributorScreenState();
}
class _ContributorScreenState extends State<ContributorScreen> with WidgetsBindingObserver {
  final session = SessionController();
  @override void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    session.initialize().catchError((Object error) { session.message = 'Setup failed: $error'; if (mounted) setState(() {}); });
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS permission dialogs temporarily make the app inactive during Start.
    if (state == AppLifecycleState.paused || (state == AppLifecycleState.inactive && session.isActive)) {
      session.stop(interrupted: true);
    }
  }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); session.dispose(); super.dispose(); }
  Future<void> settings() async {
    final url = TextEditingController(text: session.uploader.base?.toString() ?? 'https://');
    final auth = TextEditingController();
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Connect your server'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: url, decoration: const InputDecoration(labelText: 'HTTPS API address')),
        const SizedBox(height: 16),
        TextField(controller: auth, obscureText: true, decoration: const InputDecoration(labelText: 'Authorization header', hintText: 'Bearer …')),
        const SizedBox(height: 12), const Text('Credentials are stored in the iOS Keychain. Use your identity provider’s access token.'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () async {
          try { await session.configure(url.text.trim(), auth.text.trim()); if (context.mounted) Navigator.pop(context); }
          catch (error) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error'))); }
        }, child: const Text('Connect'))]));
    url.dispose(); auth.dispose();
  }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: session, builder: (context, _) {
    final active = [SessionState.collecting, SessionState.gpsCalibrating, SessionState.gpsDegraded].contains(session.state);
    return Scaffold(appBar: AppBar(title: const Text('ROADWATCH', style: TextStyle(letterSpacing: 3, fontWeight: FontWeight.w800)),
      actions: [IconButton(onPressed: session.ready ? settings : null, tooltip: 'Server settings', icon: const Icon(Icons.tune))]),
      body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('CONTRIBUTOR', style: TextStyle(color: Color(0xFFC0F27B), letterSpacing: 2, fontSize: 11)),
        const SizedBox(height: 10),
        const Text('Better roads.\nOne observation at a time.', style: TextStyle(fontSize: 29, height: 1.15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        ClipRRect(borderRadius: BorderRadius.circular(20), child: SizedBox(height: 260, child: Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: Color(0xFF26332B)),
          if (Theme.of(context).platform == TargetPlatform.iOS) const UiKitView(viewType: 'road_hazard/preview'),
          Positioned(top: 16, left: 16, child: Chip(avatar: Icon(Icons.circle, size: 10, color: active ? Colors.lightGreenAccent : Colors.grey),
            label: Text(session.state.name.replaceAllMapped(RegExp(r'[A-Z]'), (m) => ' ${m[0]}').toUpperCase()))),
          const Center(child: Icon(Icons.crop_free, size: 110, color: Colors.white54)),
          const Positioned(bottom: 16, left: 16, right: 16, child: Text('Foreground camera · Single-image evidence', style: TextStyle(fontSize: 12))),
        ]))),
        const SizedBox(height: 20),
        Row(children: [Expanded(child: metric('THIS SESSION', '${session.captured}', 'candidates')),
          Expanded(child: metric('UPLOAD QUEUE', '${session.queued}', 'pending')),
          Expanded(child: metric('GPS ACCURACY', session.fix == null ? '—' : '${session.fix!.accuracy.toStringAsFixed(0)} m', 'horizontal'))]),
        const SizedBox(height: 20),
        Text(session.message, style: const TextStyle(color: Color(0xFFB0BDB4), height: 1.5)),
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, height: 56, child: FilledButton.icon(
          onPressed: !session.ready || session.state == SessionState.requestingPermissions ? null : active ? () => session.stop() : () => session.start(),
          icon: Icon(active ? Icons.stop_rounded : Icons.play_arrow_rounded), label: Text(active ? 'Finish collection' : 'Start collection'))),
        const SizedBox(height: 18), const Text('Set up while parked. Keep the phone mounted and the app visible. Images are removed after receipt; verification happens on the server.',
          style: TextStyle(fontSize: 12, height: 1.5, color: Colors.white54)),
      ]))));
  });
  Widget metric(String label, String value, String caption) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 9, letterSpacing: 1, color: Colors.white54)),
    const SizedBox(height: 8), Text(value, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w600)),
    Text(caption, style: const TextStyle(fontSize: 11, color: Colors.white54)),
  ]);
}
