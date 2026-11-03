import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const apiBase = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://localhost:8787',
);

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, this.status);
  @override
  String toString() => message;
}

class Marketplace extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  final _http = http.Client();
  String? token;
  Map<String, dynamic>? user;
  bool initialized = false;
  bool connected = false;
  List<dynamic> categories = [];
  int revision = 0;
  int _generation = 0;
  int _cursor = 0;
  bool _recovering = false;
  Timer? _retry;
  Timer? _fallback;
  final List<WebSocketChannel> _sockets = [];
  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
    Map<String, String>? extra,
  ]) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      ...?extra,
    };
    final req = http.Request(method, Uri.parse('$apiBase/api$path'))
      ..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    final response = await http.Response.fromStream(await _http.send(req))
        .timeout(const Duration(seconds: 20));
    final data = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw ApiException(
        data['error'] ?? 'No fue posible completar la solicitud.',
        response.statusCode,
      );
    }
    return data;
  }

  Future<void> initialize() async {
    try {
      token = await _storage.read(key: 'session');
      categories = await request('GET', '/categories') as List;
      if (token != null) {
        try {
          user = Map<String, dynamic>.from(await request('GET', '/me'));
        } on ApiException catch (e) {
          if (e.status == 401) {
            token = null;
            await _storage.delete(key: 'session');
          } else {
            rethrow;
          }
        }
      }
      if (user != null) startLive();
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> login(String email, String password) async {
    final result = await request('POST', '/auth/login', {
      'email': email,
      'password': password,
    });
    token = result['token'];
    await _storage.write(key: 'session', value: token);
    user = Map<String, dynamic>.from(await request('GET', '/me'));
    startLive();
    notifyListeners();
  }

  Future<void> logout() async {
    if (token != null) await request('POST', '/auth/logout');
    _stopLive();
    token = null;
    user = null;
    _cursor = 0;
    await _storage.delete(key: 'session');
    notifyListeners();
  }

  Future<void> updateProfile(String name, String zone, bool seller) async {
    await request('PATCH', '/me', {
      'name': name,
      'zone': zone,
      'seller': seller,
    });
    user = Map<String, dynamic>.from(await request('GET', '/me'));
    notifyListeners();
  }

  void changed() {
    revision++;
    notifyListeners();
  }

  void startLive() {
    _stopLive();
    final generation = _generation;
    _connect(generation);
    _fallback = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _recover(generation),
    );
  }

  void _stopLive() {
    _generation++;
    _retry?.cancel();
    _fallback?.cancel();
    for (final socket in _sockets) {
      socket.sink.close();
    }
    _sockets.clear();
    connected = false;
  }

  Future<void> _connect(int generation) async {
    if (generation != _generation || token == null) return;
    try {
      for (final channel in ['public', 'private']) {
        final data = await request('POST', '/live/ticket', {
          'channel': channel,
        });
        if (generation != _generation) return;
        final uri = Uri.parse('$apiBase/api/live').replace(
          scheme: apiBase.startsWith('https:') ? 'wss' : 'ws',
          queryParameters: {'ticket': data['ticket']},
        );
        final socket = WebSocketChannel.connect(uri);
        _sockets.add(socket);
        await socket.ready;
        if (generation != _generation) {
          await socket.sink.close();
          return;
        }
        socket.stream.listen(
          (event) {
            if (generation != _generation || event == 'pong') return;
            // Fetch through the persisted cursor: sockets can deliver out of order.
            _recover(generation);
          },
          onError: (_) => _disconnected(generation),
          onDone: () => _disconnected(generation),
        );
      }
      connected = true;
      notifyListeners();
      await _recover(generation);
    } catch (_) {
      _disconnected(generation);
    }
  }

  void _disconnected(int generation) {
    if (generation != _generation || token == null) return;
    connected = false;
    notifyListeners();
    if (_retry?.isActive ?? false) return;
    _retry = Timer(const Duration(seconds: 5), () {
      for (final socket in _sockets) {
        socket.sink.close();
      }
      _sockets.clear();
      _generation++;
      final next = _generation;
      _fallback?.cancel();
      _fallback = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _recover(next),
      );
      _connect(next);
    });
  }

  Future<void> _recover(int generation) async {
    if (_recovering || generation != _generation || token == null) return;
    _recovering = true;
    try {
      bool more = true;
      bool updated = false;
      while (more && generation == _generation) {
        final result = await request('GET', '/events?after=$_cursor');
        final items = result['items'] as List;
        if (result['resetRequired'] == true) updated = true;
        for (final event in items) {
          _cursor = event['cursor'] as int;
          updated = true;
        }
        more = result['hasMore'] == true;
      }
      if (updated && generation == _generation) changed();
    } on ApiException catch (e) {
      if (e.status == 401 && generation == _generation) {
        _stopLive();
        token = null;
        user = null;
        await _storage.delete(key: 'session');
        notifyListeners();
      }
    } catch (_) {
      /* The visible connection indicator and retry remain active. */
    } finally {
      _recovering = false;
    }
  }

  @override
  void dispose() {
    _stopLive();
    _http.close();
    super.dispose();
  }
}
