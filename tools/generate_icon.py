"""Generate original geometric icons; requires Python 3 and Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw
import json

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'App/Resources/Assets.xcassets'
SIZE = 2048

def icon(background, accent, path):
    image = Image.new('RGBA', (SIZE, SIZE), background)
    for angle, fill in [(12, '#9CA7EE'), (-7, '#CED5FB'), (0, '#FFFFFF')]:
        layer = Image.new('RGBA', (SIZE, SIZE))
        draw = ImageDraw.Draw(layer)
        draw.rounded_rectangle((500, 360, 1548, 1668), radius=96, fill=fill)
        if angle == 0:
            draw.rounded_rectangle((660, 620, 1328, 700), radius=40, fill=accent)
            draw.rounded_rectangle((660, 820, 1190, 892), radius=36, fill=accent)
            draw.arc((830, 1070, 1218, 1458), 35, 325, fill=accent, width=64)
            draw.polygon([(1230, 1180), (1214, 1052), (1110, 1138)], fill=accent)
        image.alpha_composite(layer.rotate(angle, resample=Image.Resampling.BICUBIC))
    image.convert('RGB').resize((1024, 1024), Image.Resampling.LANCZOS).save(path)

icons = ASSETS / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
icon('#4249B7', '#4249B7', icons / 'AppIcon.png')
icon('#202345', '#373E92', icons / 'AppIcon-Dark.png')
(icons / 'Contents.json').write_text(json.dumps({'images': [
    {'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'},
    {'filename':'AppIcon-Dark.png','idiom':'universal','platform':'ios','size':'1024x1024',
     'appearances':[{'appearance':'luminosity','value':'dark'}]}],
    'info':{'author':'xcode','version':1}}, indent=2)+'\n')
