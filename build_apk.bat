@echo off
chcp 65001 >nul
echo ============================================
echo   时音 (Shiyin) - APK 构建工具
echo ============================================
echo.

setlocal
set JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8

cd /d "%~dp0"

rem ── 工具链定位（不写死盘符）──────────────────────────────────────────
rem 以前这里把 JAVA_HOME / ANDROID_HOME / flutter 全写死在 E: 盘，换机即废。
rem Flutter 查找顺序与 scripts/flutter-env.ps1 保持一致：
rem   FLUTTER_ROOT → FLUTTER_HOME → PATH → 常见安装位置
set "FLUTTER="
if defined FLUTTER_ROOT if exist "%FLUTTER_ROOT%\bin\flutter.bat" set "FLUTTER=%FLUTTER_ROOT%\bin\flutter.bat"
if not defined FLUTTER if defined FLUTTER_HOME if exist "%FLUTTER_HOME%\bin\flutter.bat" set "FLUTTER=%FLUTTER_HOME%\bin\flutter.bat"
if not defined FLUTTER for /f "delims=" %%i in ('where flutter.bat 2^>nul') do if not defined FLUTTER set "FLUTTER=%%i"
if not defined FLUTTER for %%d in ("C:\develop\flutter\flutter" "D:\develop\flutter\flutter" "E:\flutter\flutter" "C:\flutter\flutter" "D:\flutter\flutter" "C:\src\flutter" "%USERPROFILE%\flutter\flutter") do if not defined FLUTTER if exist "%%~d\bin\flutter.bat" set "FLUTTER=%%~d\bin\flutter.bat"
if not defined FLUTTER (
    echo [失败] 找不到 flutter，二选一修好再重开终端：
    echo         1^) 把 Flutter SDK 的 bin 目录加入 PATH
    echo         2^) 设置环境变量，例：setx FLUTTER_ROOT C:\develop\flutter\flutter
    pause
    exit /b 1
)

rem JAVA_HOME：已配置就沿用，否则探测含 bin\java.exe 的目录
if not defined JAVA_HOME for %%d in ("C:\develop\jdk" "C:\develop\jdk17" "C:\develop\jdk21" "C:\Program Files\Java\jdk-21" "C:\Program Files\Java\jdk-17" "E:\jdk17\jdk-17.0.12+7") do if not defined JAVA_HOME if exist "%%~d\bin\java.exe" set "JAVA_HOME=%%~d"

rem ANDROID_HOME：已配置就沿用，否则探测含 platform-tools 的目录
if not defined ANDROID_HOME for %%d in ("C:\develop\Android\SDK" "C:\develop\Android\Sdk" "%LOCALAPPDATA%\Android\Sdk" "C:\Android\Sdk" "D:\Android\Sdk") do if not defined ANDROID_HOME if exist "%%~d\platform-tools" set "ANDROID_HOME=%%~d"

if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
if defined ANDROID_HOME set "PATH=%ANDROID_HOME%\platform-tools;%PATH%"

echo [flutter] %FLUTTER%
if defined JAVA_HOME echo [JAVA_HOME] %JAVA_HOME%
if defined ANDROID_HOME echo [ANDROID_HOME] %ANDROID_HOME%
echo.

rem 用法: build_apk.bat [release^|debug]，固定 ARM64 + Impeller
set RENDERER=impeller
set BUILD_TYPE=%1
set ABI=arm64
if "%BUILD_TYPE%"=="" set BUILD_TYPE=release
if not "%BUILD_TYPE%"=="release" if not "%BUILD_TYPE%"=="debug" (
    echo [失败] 构建类型只能是 release 或 debug，当前: %BUILD_TYPE%
    pause
    exit /b 1
)

echo [渲染引擎] %RENDERER%
echo [构建类型] %BUILD_TYPE%
echo [目标 ABI] %ABI%
echo.

echo [0/4] 检查是否需要清理...
rem 切渲染器或 ABI 必须 clean：--dart-define=APP_RENDERER / APP_ABI 是
rem 编译期烘焙常量，不清可能复用上个变体的 kernel 缓存，导致关于页标签
rem 和更新选包串味。Gradle 变体产物本身是隔离的，不用担心。
rem 用 build\.last_variant（gitignored）记住上次组合，同组合走增量构建
rem 不浪费时间。
set STAMP=build\.last_variant
set VARIANT=%RENDERER%-%ABI%
set LAST_VARIANT=
if exist "%STAMP%" set /p LAST_VARIANT=<"%STAMP%"
if not "%LAST_VARIANT%"=="%VARIANT%" (
    if "%LAST_VARIANT%"=="" (
        echo 上次构建记录不存在，执行 flutter clean 确保干净构建...
    ) else (
        echo 变体切换（%LAST_VARIANT% --^> %VARIANT%），执行 flutter clean...
    )
    call "%FLUTTER%" clean
    if %ERRORLEVEL% neq 0 (
        echo [失败] clean 出错
        pause
        exit /b 1
    )
    if not exist build mkdir build
    echo %VARIANT%>"%STAMP%"
) else (
    echo 同一变体（%VARIANT%），跳过 clean，走增量构建。
)

echo.
echo [1/4] 安装依赖...
call "%FLUTTER%" pub get
if %ERRORLEVEL% neq 0 (
    echo [失败] pub get 出错
    pause
    exit /b 1
)

echo.
echo [2/4] 代码分析...
call "%FLUTTER%" analyze
if %ERRORLEVEL% neq 0 (
    echo [失败] 分析出错，请检查代码
    pause
    exit /b 1
)

echo.
echo [3/4] 构建 APK...
set FLUTTER_TARGET=android-arm64
call "%FLUTTER%" build apk --%BUILD_TYPE% --target-platform %FLUTTER_TARGET% --android-project-arg=customPackageName=com.apple.android.music
if %ERRORLEVEL% neq 0 (
    echo [失败] 构建出错
    pause
    exit /b 1
)

echo.
echo ============================================
echo   ^[成功^] 构建成功！
echo   APK：build\app\outputs\flutter-apk\app-%BUILD_TYPE%.apk
echo ============================================
echo.
echo 用法: build_apk.bat [release^|debug]，固定 ARM64 + Impeller
pause
