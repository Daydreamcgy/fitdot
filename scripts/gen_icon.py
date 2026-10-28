# -*- coding: utf-8 -*-
"""FitDot 图标：白底 + 打卡成功态按钮（蓝环 + 蓝色实心圆，无文字）。"""
from PIL import Image, ImageDraw

SIZE = 1024
CENTER = SIZE // 2
BLUE = (65, 118, 230, 255)
WHITE = (255, 255, 255, 255)

# 按打卡按钮比例缩放：按钮外径 244vp ↔ 图标 640px（安全区内），scale ≈ 2.623
S = 640.0 / 244.0
RING_WIDTH = int(round(10 * S))            # 环描边 ≈ 26px
RING_OUTER_R = int(round(122 * S))         # 环外缘半径 ≈ 320（Pillow 描边自外缘向内长）
CIRCLE_R = int(round(216 / 2 * S))         # 实心圆半径 ≈ 283

img = Image.new('RGBA', (SIZE, SIZE), WHITE)
d = ImageDraw.Draw(img)
# 外圈蓝环
d.ellipse(
    (CENTER - RING_OUTER_R, CENTER - RING_OUTER_R, CENTER + RING_OUTER_R, CENTER + RING_OUTER_R),
    outline=BLUE, width=RING_WIDTH,
)
# 内部实心蓝圆（与环之间留缝）
d.ellipse(
    (CENTER - CIRCLE_R, CENTER - CIRCLE_R, CENTER + CIRCLE_R, CENTER + CIRCLE_R),
    fill=BLUE,
)
out = img.convert('RGB')

targets = [
    r'D:\Desktop\workspace\MyProject\HMDots\entry\src\main\resources\base\media\icon.png',
    r'D:\Desktop\workspace\MyProject\HMDots\entry\src\main\resources\base\media\startIcon.png',
    r'D:\Desktop\workspace\MyProject\HMDots\AppScope\resources\base\media\app_icon.png',
]
for t in targets:
    out.save(t, 'PNG')
    print('saved:', t)
