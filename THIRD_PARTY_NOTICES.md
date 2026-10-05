# 第三方声明与参考来源

BatteryGuard 原创代码采用根目录的 [MIT 许可证](LICENSE)。第三方组件保留原许可证；下面的回链和声明不改变上游组件的授权范围。

## 风扇控制参考

- 项目：[Bei-Luo/wujie-fan-control](https://github.com/Bei-Luo/wujie-fan-control)。
- 参考范围：本机 EC 风扇寄存器、手动占空比及固件回拉时的维护思路。本仓库的 C#/PowerShell 风扇后台、策略和测试为项目自身实现。
- 许可证：MIT。Copyright (c) 2026 Mechrevo WUJIE 14X Pro fan control contributors。
- 原始版权及完整许可声明保存在 `licenses/wujie-fan-control-MIT.txt`。
- 上游 README 进一步将 I2EC 协议背景归功于 [jpy794/wujie-fan-control](https://github.com/jpy794/wujie-fan-control)。我们保留这条来源回链；未在该仓库核实到明确许可证，不复制其源文件或将其代码纳入本项目的 MIT 授权。

## RyzenAdj

- 项目：[FlyGoat/RyzenAdj](https://github.com/FlyGoat/RyzenAdj)，使用版本 [v0.19.0](https://github.com/FlyGoat/RyzenAdj/tree/v0.19.0)。
- 作者：Jiaxun Yang / FlyGoat 及贡献者。
- 许可证：GNU LGPLv3，完整上游许可保存在 `driver/ryzenadj/LICENSE`。
- 使用方式：调用独立动态库。源码预览包不包含 RyzenAdj 二进制文件，也没有将该库源代码并入我们的原创代码。
- 分发库的二进制或修改版时，应保留原始声明、履行对应源码提供义务，并保障动态库替换及 LGPL 为此要求的使用权。根目录 MIT 不替代这些要求。

## InpOut

- 来源：[Highrez InpOut](https://www.highrez.co.uk/downloads/inpout32/default.htm)。
- 作者：Phil Gibbons / Highrez；部分版权归 logix4u.net。
- 许可证：上游 MIT 风格授权，完整版权及许可保存在 `driver/license.txt`。
- 源码包不包含其 DLL 或驱动。分发对应文件时应同时保留该声明。

## WinRing0 / OpenLibSys

本程序调用上游 RyzenAdj Windows 分发中提供的 WinRing0 库和驱动。源码包只保留依赖名称和校验值，不包含相关二进制或实现源代码。当前未为这组具体二进制核实完整、对应版本的原始许可文本，因此不以 BatteryGuard 的 MIT 授权重新分发它们；后续若制作含二进制的安装包，需先完成来源及许可证核对。

## 授权边界

参考硬件事实或实现思路、保留第三方动态库接口，与复制并重新授权第三方代码是不同事项。没有许可证也不等于没有限制；未经明确授权的上游代码不进入本源码包。原始引用和库的许可证声明随源码保留，用户应按相应组件的许可证使用和分发。
