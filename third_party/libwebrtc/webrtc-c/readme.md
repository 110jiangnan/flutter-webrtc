# webrtc-c 编译

## 方式1: cmake + MSBuild (Windows)

在 VS 2022 Developer Command Prompt 或 PowerShell 中：

```powershell
cd build_win
& "E:\app\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" .. -G "Visual Studio 17 2022" -A x64
& "E:\app\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe" webrtc_c.sln /p:Configuration=Release /m
```

产物: `build_win\Release\webrtc_c.dll`