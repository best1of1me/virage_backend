import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';
import 'code_generator.dart';
import 'db.dart';

class AppRouter {
  static String get _chargilySecretKey =>
      Platform.environment['CHARGILY_SECRET_KEY'] ??
      'test_sk_6mJk8N1EpuR1FCTdFWf5NocUq4jsrCjFxdD5HeZw';

  Router get router {
    final app = Router();

    // Health Check
    app.get('/', (Request req) {
      return Response.ok(
        jsonEncode({
          'status': 'online',
          'message': 'Virage Backend is running',
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    // 1. إنشاء رابط دفع (مع دعم خصم الإحالة 10% لأول عملية شراء)
    app.post('/api/create-checkout', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 10;
        final num baseAmount = body['amount'] ?? 2000;

        if (schoolId == null || schoolId.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        num finalAmount = baseAmount;

        // التحقق مما إذا كانت المدرسة مسجلة عبر إحالة ولم تستفد من الخصم من قبل
        final referralCheck = await DatabaseService.client
            .from('referrals')
            .select('id, reward_granted')
            .eq('referee_id', schoolId)
            .maybeSingle();

        if (referralCheck != null && referralCheck['reward_granted'] == false) {
          finalAmount = baseAmount * 0.9; // خصم 10% على أول عملية شراء
        }

        final chargilyResponse = await http.post(
          Uri.parse('https://pay.chargily.net/test/api/v2/checkouts'),
          headers: {
            'Authorization': 'Bearer $_chargilySecretKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'amount': finalAmount,
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
          body: jsonEncode({
            'error': 'فشل إنشاء عملية الدفع',
            'details': jsonDecode(chargilyResponse.body),
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

    // 2. استقبال إشعارات الدفع (Webhook مع منح مكافأة الإحالة)
    app.post('/api/webhook/chargily', (Request req) async {
      try {
        final rawBody = await req.readAsString();
        final signature =
            req.headers['x-chargily-signature'] ?? req.headers['signature'];

        print('Webhook Received. Signature Header: $signature');

        if (signature == null || !_verifySignature(rawBody, signature)) {
          print('Webhook Error: Signature verification failed!');
          return Response.forbidden(
            jsonEncode({'error': 'توقيع الطلب غير صالح'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final event = jsonDecode(rawBody);
        print('Webhook Event Type: ${event['type']}');

        if (event['type'] == 'checkout.paid') {
          final checkout = event['data'] ?? {};
          final metadata = checkout['metadata'] ?? {};

          final String? schoolId = metadata['school_id']?.toString();
          final int count =
              int.tryParse(metadata['count']?.toString() ?? '10') ?? 10;

          if (schoolId == null || schoolId.isEmpty) {
            print('Webhook Error: school_id is missing in metadata');
            return Response.badRequest(
              body: jsonEncode({
                'error': 'school_id مفقود في البيانات الإضافية',
              }),
              headers: {'content-type': 'application/json'},
            );
          }

          // 1. توليد وإدراج أكواد التفعيل للمدرسة التي قامت بالشراء
          final List<Map<String, dynamic>> rowsToInsert = [];
          for (var i = 0; i < count; i++) {
            rowsToInsert.add({
              'code': CodeGenerator.generate(length: 8),
              'school_id': schoolId,
              'status': 'unused',
            });
          }

          print(
            'Inserting $count codes into database for school: $schoolId...',
          );
          await DatabaseService.client
              .from('activation_codes')
              .insert(rowsToInsert);
          print('Activation codes created successfully.');

          // 2. معالجة مكافأة الإحالة (منح 10 أكواد للمُحيل لمرة واحدة)
          final checkReferral = await DatabaseService.client
              .from('referrals')
              .select('id, referrer_id, reward_granted')
              .eq('referee_id', schoolId)
              .maybeSingle();

          if (checkReferral != null &&
              checkReferral['reward_granted'] == false) {
            final String referrerId = checkReferral['referrer_id'];

            final List<Map<String, dynamic>> bonusCodes = [];
            for (var i = 0; i < 10; i++) {
              bonusCodes.add({
                'code': CodeGenerator.generate(length: 8),
                'school_id': referrerId,
                'status': 'unused',
              });
            }

            // إدراج 10 أكواد هدية للمدرسة المُحيلة
            await DatabaseService.client
                .from('activation_codes')
                .insert(bonusCodes);

            // تحديث حالة المكافأة لتصبح ممنوحة حتى لا تكرر
            await DatabaseService.client
                .from('referrals')
                .update({'reward_granted': true})
                .eq('id', checkReferral['id']);

            print(
              'Referral reward granted successfully to referrer: $referrerId',
            );
          }
        }

        return Response.ok(
          jsonEncode({'status': 'success'}),
          headers: {'content-type': 'application/json'},
        );
      } on PostgrestException catch (pgError) {
        print('Supabase Postgrest Error during Webhook:');
        print('Message: ${pgError.message}');
        print('Details: ${pgError.details}');
        print('Hint: ${pgError.hint}');
        print('Code: ${pgError.code}');
        return Response.internalServerError(
          body: jsonEncode({
            'error': 'فشل الحفظ في قاعدة البيانات',
            'details': pgError.message,
            'code': pgError.code,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e, stackTrace) {
        print('Webhook General Exception: $e');
        print(stackTrace);
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 3. توليد أكواد تفعيل يدويًا
    app.post('/api/generate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? schoolId = body['school_id'];
        final int count = body['count'] ?? 1;

        if (schoolId == null || schoolId.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': 'school_id مطلوب'}),
            headers: {'content-type': 'application/json'},
          );
        }

        final List<String> generatedCodes = [];
        final List<Map<String, dynamic>> rowsToInsert = [];

        for (var i = 0; i < count; i++) {
          final code = CodeGenerator.generate(length: 8);
          generatedCodes.add(code);
          rowsToInsert.add({
            'code': code,
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
      } on PostgrestException catch (pgError) {
        return Response.internalServerError(
          body: jsonEncode({
            'error': 'فشل إدخال الأكواد في قاعدة البيانات',
            'details': pgError.message,
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

    // 4. جلب قائمة الأكواد
    app.get('/api/codes', (Request req) async {
      try {
        final schoolId = req.url.queryParameters['school_id'];
        final status = req.url.queryParameters['status'];

        if (schoolId == null || schoolId.isEmpty) {
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
      } on PostgrestException catch (pgError) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': pgError.message}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 5. تفعيل الكود
    app.post('/api/activate', (Request req) async {
      try {
        final bodyJson = await req.readAsString();
        final body = jsonDecode(bodyJson);
        final String? code = body['code'];

        if (code == null || code.isEmpty) {
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
      } on PostgrestException catch (pgError) {
        return Response.internalServerError(
          body: jsonEncode({'error_details': pgError.message}),
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

  bool _verifySignature(String payload, String signature) {
    final hmac = Hmac(sha256, utf8.encode(_chargilySecretKey));
    final digest = hmac.convert(utf8.encode(payload));
    return digest.toString() == signature;
  }
}
