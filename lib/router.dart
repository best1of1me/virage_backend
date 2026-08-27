import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'code_generator.dart';
import 'db.dart';

class AppRouter {
  static const String _chargilySecretKey = 'YOUR_CHARGILY_SECRET_KEY';

  Router get router {
    final app = Router();

    // مسار الصفحة الرئيسية لفحص عمل الخادم (Health Check)
    app.get('/', (Request req) {
      return Response.ok(
        jsonEncode({
          'status': 'online',
          'message': 'Virage Backend is running',
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    // 1. إنشاء رابط دفع عن طريق Chargily Pay v2
    app.post('/api/create-checkout', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 10;
        final num amount = body['amount'] ?? 2000;

        if (schoolId == null) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final chargilyResponse = await http.post(
          Uri.parse('https://pay.chargily.net/test/api/v2/checkouts'),
          headers: {
            'Authorization': 'Bearer $_chargilySecretKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'amount': amount,
            'currency': 'dzd',
            'success_url': 'https://virage.app/success',
            'failure_url': 'https://virage.app/failure',
            'metadata': {'school_id': schoolId, 'count': count},
          }),
        );

        if (chargilyResponse.statusCode == 200 ||
            chargilyResponse.statusCode == 201) {
          final resBody = jsonDecode(chargilyResponse.body);
          return Response.ok(
            jsonEncode({'checkout_url': resBody['checkout_url']}),
            headers: {'content-type': 'application/json'},
          );
        }

        return Response.internalServerError(
          body: jsonEncode({'error': 'فشل إنشاء عملية الدفع'}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 2. استقبال إشعارات الدفع (Webhook) وتوليد الأكواد تلقائيًا
    app.post('/api/webhook/chargily', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final event = jsonDecode(bodyJson);

        if (event['type'] == 'checkout.paid') {
          final checkout = event['data'];
          final metadata = checkout['metadata'];
          final String schoolId = metadata['school_id'];
          final int count = metadata['count'] ?? 10;

          final existingRows = await DatabaseService.client
              .from('activation_codes')
              .select('code');

          final Set<String> existingCodes = (existingRows as List)
              .map((e) => e['code'].toString())
              .toSet();

          final List<String> generatedCodes = [];
          final List<Map<String, dynamic>> rowsToInsert = [];

          for (var i = 0; i < count; i++) {
            String newCode;
            do {
              newCode = CodeGenerator.generate(length: 8);
            } while (existingCodes.contains(newCode) ||
                generatedCodes.contains(newCode));

            generatedCodes.add(newCode);
            rowsToInsert.add({
              'code': newCode,
              'school_id': schoolId,
              'status': 'unused',
            });
          }

          await DatabaseService.client
              .from('activation_codes')
              .insert(rowsToInsert);
        }

        return Response.ok(
          jsonEncode({'status': 'success'}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 3. توليد أكواد تفعيل جديدة يدويًا (لصالح مدرسة سياقة)
    app.post('/api/generate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 1;

        if (schoolId == null) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final List<String> generatedCodes = [];
        final List<Map<String, dynamic>> rowsToInsert = [];

        final existingRows = await DatabaseService.client
            .from('activation_codes')
            .select('code');

        final Set<String> existingCodes = (existingRows as List)
            .map((e) => e['code'].toString())
            .toSet();

        for (var i = 0; i < count; i++) {
          String newCode;
          do {
            newCode = CodeGenerator.generate(length: 8);
          } while (existingCodes.contains(newCode) ||
              generatedCodes.contains(newCode));

          generatedCodes.add(newCode);
          rowsToInsert.add({
            'code': newCode,
            'school_id': schoolId,
            'status': 'unused',
          });
        }

        await DatabaseService.client
            .from('activation_codes')
            .insert(rowsToInsert);

        return Response.ok(
          jsonEncode({
            'message': 'تم توليد الأكواد بنجاح',
            'codes': generatedCodes,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 4. جلب قائمة الأكواد الخاصة بمدرسة سياقة محددة
    app.get('/api/codes', (Request req) async {
      final schoolId = req.url.queryParameters['school_id'];
      final status = req.url.queryParameters['status'];

      if (schoolId == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'school_id مطلوب'}),
          headers: {'content-type': 'application/json'},
        );
      }

      var query = DatabaseService.client
          .from('activation_codes')
          .select('code, status, activated_at, created_at')
          .eq('school_id', schoolId);

      if (status != null && status.isNotEmpty) {
        query = query.eq('status', status);
      }

      final response = await query.order('created_at', ascending: false);

      return Response.ok(
        jsonEncode(response),
        headers: {'content-type': 'application/json'},
      );
    });

    // 5. تفعيل الكود من اللوحة
    app.post('/api/activate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? code = body['code'];

        if (code == null) {
          return Response.badRequest(
            body: jsonEncode({'error': 'الكود مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final check = await DatabaseService.client
            .from('activation_codes')
            .select('status')
            .eq('code', code)
            .maybeSingle();

        if (check == null) {
          return Response.notFound(
            jsonEncode({'error': 'رمز التفعيل غير صحيح'}),
            headers: {'content-type': 'application/json'},
          );
        }

        if (check['status'] == 'activated') {
          return Response.badRequest(
            body: jsonEncode({'error': 'تم استخدام هذا الرمز من قبل'}),
            headers: {'content-type': 'application/json'},
          );
        }

        await DatabaseService.client
            .from('activation_codes')
            .update({
              'status': 'activated',
              'activated_at': DateTime.now().toIso8601String(),
            })
            .eq('code', code);

        return Response.ok(
          jsonEncode({'message': 'تم تفعيل الكود بنجاح'}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    return app;
  }
}
