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

**方案 A(推荐):单张 CPU 渲染的边框纹理 + 一个 `wlr.SceneBuffer` 取代 4 个 rect。**

- 分配 ARGB8888 缓冲区,尺寸 `(content.width + 2*bw) × (content.height + 2*bw)`,节点置于窗口树内 `(-bw, -bw)`。
- 填充:
  - 四条边条:逐行/列直填(轴对齐,无需 AA)。
  - 四角:仅遍历每个 `r×r` 角区,逐像素求覆盖度 `alpha = clamp(r - dist((x,y),(r,r)), 0, 1)` 得到 1px 软边(解析 AA,无锯齿)。r 为圆角半径,bw < r 时角部呈月牙形过渡;bw ≥ r 时天然退化为直角(由 r 配置约束)。
  - 像素预乘 alpha(与 wlroots 混合模式一致,保证半透明边框颜色正确)。
- 上屏:自定义 `wlr.Buffer`(实现 `wlr_buffer_impl` 的 `get_shm` / `begin_data_ptr_access`,zig-wlroots 的 `wlr.Buffer.init` 已可用),`wlr_scene_buffer_set_buffer` 接替或重建;每次 `drawBorders()`(颜色/宽度/尺寸/edges 变化时)重填纹理。边框面积 ≈ 周长×bw,开销可忽略。
- 裁剪兼容:现有每边 rect 与 `requested.clip` 的矩形求交改为 CPU 填充时跳过 clip 外像素(同一坐标空间)。
- edges 位掩码(平铺窗口只画部分边):按已画边生成对应边条;圆角仅出现在两条相邻边都存在的角。
- 全屏/无边框窗口(`width=0` 或不画边):纹理尺寸为 0 或禁用节点,与现状等价。

**方案 B(不推荐,仅作对照):每角用 N 个细长 rect 阶梯逼近圆弧。** 零纹理、改动最小,但锯齿明显、节点数暴增(每窗口 ~4r 个节点),仅适合 3 天临时效果。**方案 A 失败时才考虑。**

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
river/Window.zig        → drawBorders() 重写为纹理填充;Border 渲染逻辑所在(唯一改动核心)
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
- 新增一个 `assert` 自检(如 `Window.zig` 内 `test "rounded corner coverage"`):对角区像素做几何断言(角点外像素 alpha=0、圆弧内侧 alpha=255、过渡带 0<alpha<255),保证覆盖度公式不回归。
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