# Spec: 圆角窗口边框 (Rounded Window Borders)

## Objective

将窗口边框的四角裁为圆角:窗口外轮廓呈圆角矩形,边框拐角处由四分之一圆弧过渡,窗口内容区域保持直角不变。

- 用户:本 fork(river-paddd)的使用者,当前已接受若干自定义补丁(touchpad 手势键等)。
- 成功形态:任意带边框的窗口,四角外沿为平滑圆弧(无锯齿),内容区、拖动、点击、焦点行为与现状一致。

## 现状(已核实)

- 边框由 WM 进程经 `river-window-management-v1` 的 `set_borders` 下发,合成器存于 `Window.rendering_requested.border`(`river/Window.zig`)。
- `Window.drawBorders()` 用 **4 个 `wlr.SceneRect`**(left/right/top/bottom)绘制,直角拐角靠 left/right 矩形纵向延伸盖住 bw×bw 角方块(`river/Window.zig:979-1052`)。
- wlroots 0.20 场景图与渲染通道 **均无圆角/椭圆图元**:图元只有 `wlr_scene_rect`、`wlr_scene_buffer`、`wlr_scene_surface`;裁剪只有矩形 box(`wlr_scene_subsurface_tree_set_clip`)与 `pixman_region32_t` 矩形区域(`wlr_render_pass_add_rect` 的 clip)。**结论:矩形图元无法拼出圆角,必须走纹理。**
- 命中测试:窗口树根 `window.tree.node` 携带 `.window` 数据(`SceneNodeData`),`Scene.at()` 沿父链回溯(`river/SceneNodeData.zig:43-46`),故边框换成任意节点类型不改变点击归属;目前角方块本就被 side rects 覆盖,圆角后空出的三角区点击仍命中窗口,无行为回归。

## 技术方案(设计)

**方案 A(已实现):边条用 `wlr.SceneRect`,四角用 `r×r` CPU 渲染纹理。**

- 分解依据:`ringCoverage()` 在四个 `max(r, bw)` 见方的角区之外取值恒为 0 或 1,因此边条可以是纯色矩形,只有角部需要 AA 纹理(分解的逐像素精确性由单测保证)。
- 边条:4 个 `wlr.SceneRect`,按 edges 位掩码决定画出与否,并与 `requested.clip` 求交;侧条仅在相邻水平边存在时纵向延伸(沿用旧 rect 契约)。
- 四角:每角一张 `size×size`(size = max(r, bw))ARGB8888 纹理,自定义 `wlr.Buffer`(实现 `wlr_buffer_impl` 的 `get_shm` / `begin_data_ptr_access`)。逐像素覆盖度 `alpha = clamp(r - dist((x,y),(r,r)), 0, 1)` 得到 1px 软边;`bw < r` 时角部含月牙形 band;预乘 alpha。clip 外的像素写 0(透明)。
- 开销:每窗口四张 `size²` 纹理(r≤10 → 400 px/角,合计 ~1.6 KB),与全帧纹理方案(4K 窗口 ~33 MB + 全屏填充率)相比内存与带宽降低约 4 个数量级;边条为零纹理矩形。尺寸/edges/颜色/clip 变化时重建。
- 内容不溢出:wlroots 0.20 场景图无法对客户端内容做圆角裁剪(只有矩形 clip),因此有效半径按边框宽度收敛:
  `r_eff = min(10, floor((bw + 0.5)·(2+√2)))`,保证内容方角保持在圆弧内侧(如 bw=2 → r=8)。
- 已知退化:极窄窗口(`min(fw,fh) < 2·size`)四角纹理可能彼此重叠,半透明边框在该处会叠加两次;不透明边框无差异。
- 全屏/无边框窗口(`width=0` 或不画边):禁用全部节点,与现状等价。

**配置入口(待定,见 Open Questions):**

- 有效半径 = 合成器端常量(10px)+ 边框宽度,随宽度联动,不碰协议。后续如需自由可配:在 `set_borders` 请求中新增 `radius` 参数(跨仓库,未做)。
- 后续若需可配置:在 `set_borders` 请求中新增 `radius` 参数(`protocol/river-window-management-v1.xml` + 另一仓库的 WM 端)——跨仓库改动,属 Ask-first。

## Tech Stack

- Zig 0.16.x + wlroots 0.20.1(zig-wlroots 绑定,zig-pkg 内置)、pixman(已为依赖,可用于覆盖度计算或省略)。

## Commands

```
Build: zig build -Doptimize=ReleaseSafe --prefix ~/.local install
       # Xwayland 需要:zig build -Dxwayland
Test:  zig build test          # 运行单元测试
Doc:   zig build -Dmanual    # (如有)
```

## Project Structure

```
river/Window.zig        → drawBorders() 重写为"边条 rect + 四角小纹理";Border 渲染逻辑所在(唯一改动核心)
river/                → 若引入覆盖度计算,优先内联于 Window.zig,避免新文件
SPEC-rounded-window-borders.md → 本文档
```

**原则:只改 `river/Window.zig`(最多 + 一个自检函数或小测试文件),不新增模块。**

## Code Style

跟随仓库现有风格:Zig,`std.debug.assert`、显式错误处理、`wlr.Buffer`/`wlr.SceneBuffer` 走绑定层。示例风格(仅示意,以现有 `drawBorders` 的写法为准):

```zig
// 角覆盖度:距离外角点 (r,r) 超过半径的像素剔除,1px 线性过渡
const dist = @sqrt(@as(f64, @floatFromInt(dx*dx + dy*dy)));
const cov: u8 = @intFromFloat(@max(0, @min(1, r - dist)) * 255);
```

## Testing Strategy

- 现有 `zig build test` 保持不变,不引入测试框架。
- 新增 `assert` 自检(`Window.zig` 内 `test "rounded border corner coverage"` 等):对角区像素做几何断言(角点外像素 alpha=0、圆弧内侧 alpha=255、过渡带 0<alpha<255),保证覆盖度公式不回归;`test "border geometry covers exactly the ring"` 逐像素验证"边条 rect ∪ 四角方块"恰好等于环覆盖非零区且无重叠;`test "border geometry keeps the strips clear of the corners"` 固定几何数值。
- 视觉验证(人工,计入成功标准):`river` 起合成器,开几个带边框窗口,检查四角、半透明边框、平铺相邻边、拖拽。

## Boundaries

- Always:提交前跑 `zig build test`;遵循仓库命名/风格;保留现有命中测试与裁剪语义(Cursor/Seat 零改动)。
- Ask first:修改 `river-window-management-v1.xml` 协议、跨仓库(WM 端)改动、改动边框几何语义(如同时圆内容角)。
- Never:不并发改动 Cursor/Seat/输入路径;不在本次引入通用"圆角遮罩"框架。

## Success Criteria

1. 带边框窗口四角为平滑圆弧,边缘无可见锯齿(1px AA),半径 r 观感约 8-12px。
2. 内容区域保持直角,内容不被裁切。
3. 半透明边框颜色在圆角处混合正确(无黑边/色偏)。
4. 点击、hover、拖拽移动、平铺部分边、全屏、隐藏等现有行为与实现前一致(无输入路径改动)。
5. 尺寸/颜色连续变化(布局调整、resize)时边框实时跟随,无闪烁。
6. `zig build test` 通过,含新增角覆盖度自检。

## Open Questions

1. 圆角半径值:固定常量(如 10px)即达视觉目标?还是需要 `set_borders` 带 radius 可配置(跨仓库)?
2. 是否需要"仅某些角圆角"(如仅顶部两角)?当前理解:四角全圆。
3. 边框宽度可变区间:bw ≥ r 时圆角消失——已解决:有效半径 = 10px + 边框宽,任意宽度下圆角保持可见。
4. 最大化窗口:保持矩形不圆角,还是同样圆角?(默认:与平铺一致,统一处理)