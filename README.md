# Windows一键优化

找「莫名卡顿」的常见原因，勾选后一键修复。不自动结束程序、不删文件；需要管理员时才弹 UAC。

## 运行

双击 `启动.bat`（Windows 10 / 11，无需安装）。详见 `使用说明.txt`。

## 开发

```powershell
powershell -STA -ExecutionPolicy Bypass -File .\WinOptimizer.ps1
# CI 冒烟（加载界面、体检、截图后退出）
powershell -STA -ExecutionPolicy Bypass -File .\WinOptimizer.ps1 -Smoke
# 不打开窗口：按 Windows 10（19045）检查建议项，并做可恢复的往返
powershell -STA -ExecutionPolicy Bypass -File .\WinOptimizer.ps1 -SelfTest -MockBuild 19045
```

## License

MIT
