# ESP-IDF v5.5.2 环境初始化脚本
$env:IDF_PATH = "D:\Espressif\frameworks\esp-idf-v5.5.2"
$env:IDF_PYTHON_ENV_PATH = "D:\Espressif\python_env\idf5.5_py3.11_env"
$env:PATH = "$env:IDF_PYTHON_ENV_PATH\Scripts;$env:PATH"

# 添加工具链到 PATH
$toolPaths = @(
    "D:\Espressif\tools\xtensa-esp-elf\esp-14.2.0_20251107\xtensa-esp-elf\bin"
    "D:\Espressif\tools\riscv32-esp-elf\esp-14.2.0_20251107\riscv32-esp-elf\bin"
    "D:\Espressif\tools\esp32ulp-elf\2.38_20240113\esp32ulp-elf\bin"
    "D:\Espressif\tools\cmake\3.30.2\bin"
    "D:\Espressif\tools\ninja\1.12.1"
    "D:\Espressif\tools\idf-exe\1.0.3"
    "D:\Espressif\tools\ccache\4.11.2\ccache-4.11.2-windows-x86_64"
    "D:\Espressif\tools\dfu-util\0.11"
)

foreach ($path in $toolPaths) {
    if (Test-Path $path) {
        $env:PATH = "$path;$env:PATH"
    }
}

Write-Host "ESP-IDF v5.5.2 环境已初始化!" -ForegroundColor Green
Write-Host "IDF_PATH: $env:IDF_PATH" -ForegroundColor Cyan
Write-Host "Python: $(python --version)" -ForegroundColor Cyan

# 验证
& python "$env:IDF_PATH\tools\idf.py" --version
