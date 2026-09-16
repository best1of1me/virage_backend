import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

class _NewApiKeyBearerStrippingClient extends http.BaseClient {
  _NewApiKeyBearerStrippingClient(this._inner, this._key);

  final http.Client _inner;
  final String _key;

  bool get _isNewFormat =>
      _key.startsWith('sb_publishable_') || _key.startsWith('sb_secret_');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_isNewFormat) {
      final authorization = request.headers['Authorization'];
      if (authorization != null && authorization == 'Bearer $_key') {
        request.headers.remove('Authorization');
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class DatabaseService {
  static late SupabaseClient client;

  static void init() {
    final supabaseUrl =
        Platform.environment['SUPABASE_URL'] ??
        'https://gwafzhdtrqvwakawjmwm.supabase.co';

    final supabaseKey = Platform.environment['SUPABASE_SERVICE_ROLE_KEY'];
    if (supabaseKey == null || supabaseKey.isEmpty) {
      throw StateError('SUPABASE_SERVICE_ROLE_KEY غير مضبوط في بيئة التشغيل');
    }

    client = SupabaseClient(
      supabaseUrl,
      supabaseKey,
      httpClient: _NewApiKeyBearerStrippingClient(http.Client(), supabaseKey),
    );
  }
}
