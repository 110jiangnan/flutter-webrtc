// hook/build.dart
import 'dart:io';
import 'package:hooks/hooks.dart';
import 'package:code_assets/code_assets.dart';

Future<void> main(List<String> args) async {
  // build 函数是 hooks 提供的入口
  await build(args, (input, output) async {
    // 只在构建原生代码资产时执行（通常为 true）
    if (input.config.buildCodeAssets) {
      // 获取当前包的名称（用于资产归属）
      final packageName = input.packageName;
      var list = <String>[];
      if (Platform.isWindows) {
        list = [
          '../third_party/libwebrtc/lib/win64/libwebrtc.dll',
          '../third_party/libwebrtc/webrtc-c/build_vs/Release/webrtc_c.dll',
          '../third_party/libwebrtc/webrtc-c/build_vs/Release/webrtc_c.lib',
        ];
      } else if (Platform.isMacOS) {
        list = [
          'native/libwebrtc_c.dylib',
        ];
      }

      for(var item in list) {
        // 检查文件是否存在
        var dllFile = File(item);
        dllFile = File(dllFile.absolute.path);
        if (!await dllFile.exists()) {
          // 你可以选择忽略或抛出异常
          print('Warning: Native library not found at ${dllFile.path}');
          return;
        }

        // 将 DLL 添加为代码资产
        // 注意：CodeAsset 需要指定 name（在 Dart 中通过 DynamicLibrary.open 加载时使用的名字）
        // 以及 linkMode，对于动态库通常用 DynamicLoadingBundled()
        output.assets.code.add(
          CodeAsset(
            package: packageName,
            name: dllFile.path.split('/').last,          // 加载时的标识，可自定义
            linkMode: DynamicLoadingBundled(),
            file: dllFile.uri,          // 源文件的 URI
          ),
        );

        // 可选：将文件本身加入依赖列表，以便缓存失效
        output.dependencies.add(dllFile.uri);
      }
    }
  });
}