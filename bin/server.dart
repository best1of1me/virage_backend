import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:virage_backend/db.dart';
import 'package:virage_backend/router.dart';

void main() async {
  // تهيئة Supabase
  DatabaseService.init();

  final appRouter = AppRouter();
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler(appRouter.router.call);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);

  print('الخادم يعمل على المنفذ: ${server.port}');
}

Middleware _corsMiddleware() {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
        'Origin, Content-Type, Authorization, Accept, X-Requested-With',
  };

  return (Handler innerHandler) {
    return (Request request) async {
      // معالجة طلب Preflight المسبق فورًا
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsHeaders);
      }

      final response = await innerHandler(request);

      // دمج الترويسات لضمان عدم ضياع الترويسات الأصلية للطلب
      final updatedHeaders = Map<String, String>.from(response.headers)
        ..addAll(corsHeaders);

      return response.change(headers: updatedHeaders);
    };
  };
}
