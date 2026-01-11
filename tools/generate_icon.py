#!/usr/bin/env python3
"""
Generate MarmotIM app icon - a cute marmot (ground squirrel)
"""

import os
import math

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("Please install Pillow: pip install Pillow")
    exit(1)

def create_marmot_icon(size):
    """Create a cute marmot icon at the specified size."""
    # Create image with transparent background
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Calculate proportions
    center_x = size // 2
    center_y = size // 2

    # Colors (cute marmot palette)
    body_color = (139, 90, 43)      # Brown body
    belly_color = (222, 184, 135)    # Tan belly
    nose_color = (60, 30, 15)        # Dark brown nose
    eye_color = (30, 15, 5)          # Very dark brown eyes
    eye_shine = (255, 255, 255)      # White eye shine
    ear_inner = (255, 182, 193)      # Pink ear inner
    cheek_color = (255, 192, 203, 150)  # Rosy cheeks

    # Background circle (optional - for visibility)
    bg_radius = int(size * 0.45)
    draw.ellipse(
        [center_x - bg_radius, center_y - bg_radius,
         center_x + bg_radius, center_y + bg_radius],
        fill=(255, 248, 240)  # Warm white background
    )

    # Body/Face - main brown circle
    body_radius = int(size * 0.38)
    body_y_offset = int(size * 0.02)  # Slightly lower
    draw.ellipse(
        [center_x - body_radius, center_y - body_radius + body_y_offset,
         center_x + body_radius, center_y + body_radius + body_y_offset],
        fill=body_color
    )

    # Belly/Face lower part - tan color
    belly_radius = int(size * 0.28)
    belly_y_offset = int(size * 0.12)
    draw.ellipse(
        [center_x - belly_radius, center_y - belly_radius + belly_y_offset,
         center_x + belly_radius, center_y + belly_radius + belly_y_offset],
        fill=belly_color
    )

    # Ears - two rounded triangles on top
    ear_width = int(size * 0.12)
    ear_height = int(size * 0.15)
    ear_y = center_y - int(size * 0.28)

    # Left ear
    left_ear_x = center_x - int(size * 0.22)
    draw.ellipse(
        [left_ear_x - ear_width//2, ear_y - ear_height//2,
         left_ear_x + ear_width//2, ear_y + ear_height//2],
        fill=body_color
    )
    # Left ear inner
    inner_w = int(ear_width * 0.5)
    inner_h = int(ear_height * 0.5)
    draw.ellipse(
        [left_ear_x - inner_w//2, ear_y - inner_h//2,
         left_ear_x + inner_w//2, ear_y + inner_h//2],
        fill=ear_inner
    )

    # Right ear
    right_ear_x = center_x + int(size * 0.22)
    draw.ellipse(
        [right_ear_x - ear_width//2, ear_y - ear_height//2,
         right_ear_x + ear_width//2, ear_y + ear_height//2],
        fill=body_color
    )
    # Right ear inner
    draw.ellipse(
        [right_ear_x - inner_w//2, ear_y - inner_h//2,
         right_ear_x + inner_w//2, ear_y + inner_h//2],
        fill=ear_inner
    )

    # Eyes
    eye_radius = int(size * 0.08)
    eye_y = center_y - int(size * 0.05)
    eye_spacing = int(size * 0.15)

    # Left eye
    left_eye_x = center_x - eye_spacing
    draw.ellipse(
        [left_eye_x - eye_radius, eye_y - eye_radius,
         left_eye_x + eye_radius, eye_y + eye_radius],
        fill=eye_color
    )
    # Eye shine
    shine_radius = int(eye_radius * 0.35)
    shine_offset = int(eye_radius * 0.3)
    draw.ellipse(
        [left_eye_x - shine_offset - shine_radius, eye_y - shine_offset - shine_radius,
         left_eye_x - shine_offset + shine_radius, eye_y - shine_offset + shine_radius],
        fill=eye_shine
    )

    # Right eye
    right_eye_x = center_x + eye_spacing
    draw.ellipse(
        [right_eye_x - eye_radius, eye_y - eye_radius,
         right_eye_x + eye_radius, eye_y + eye_radius],
        fill=eye_color
    )
    # Eye shine
    draw.ellipse(
        [right_eye_x - shine_offset - shine_radius, eye_y - shine_offset - shine_radius,
         right_eye_x - shine_offset + shine_radius, eye_y - shine_offset + shine_radius],
        fill=eye_shine
    )

    # Nose
    nose_radius = int(size * 0.05)
    nose_y = center_y + int(size * 0.08)
    draw.ellipse(
        [center_x - nose_radius, nose_y - int(nose_radius * 0.7),
         center_x + nose_radius, nose_y + int(nose_radius * 0.7)],
        fill=nose_color
    )

    # Mouth - simple curved line
    mouth_y = nose_y + int(size * 0.05)
    mouth_width = int(size * 0.08)
    # Draw small smile arcs
    for dx in [-1, 1]:
        draw.arc(
            [center_x + dx * int(size * 0.02) - mouth_width//2, mouth_y - int(size * 0.03),
             center_x + dx * int(size * 0.02) + mouth_width//2, mouth_y + int(size * 0.03)],
            start=10, end=170,
            fill=nose_color,
            width=max(1, size // 64)
        )

    # Cheeks - rosy circles (use semi-transparent overlay)
    if size >= 64:  # Only draw cheeks for larger sizes
        cheek_radius = int(size * 0.06)
        cheek_y = eye_y + int(size * 0.12)

        # Create a separate layer for cheeks with transparency
        cheek_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        cheek_draw = ImageDraw.Draw(cheek_layer)

        # Left cheek
        left_cheek_x = center_x - int(size * 0.22)
        cheek_draw.ellipse(
            [left_cheek_x - cheek_radius, cheek_y - cheek_radius,
             left_cheek_x + cheek_radius, cheek_y + cheek_radius],
            fill=(255, 150, 150, 100)
        )

        # Right cheek
        right_cheek_x = center_x + int(size * 0.22)
        cheek_draw.ellipse(
            [right_cheek_x - cheek_radius, cheek_y - cheek_radius,
             right_cheek_x + cheek_radius, cheek_y + cheek_radius],
            fill=(255, 150, 150, 100)
        )

        img = Image.alpha_composite(img, cheek_layer)

    # Add whisker dots on cheeks
    whisker_radius = max(1, size // 80)
    whisker_y = nose_y + int(size * 0.02)
    for dx in [-1, 1]:
        for i in range(2):
            wx = center_x + dx * (int(size * 0.12) + i * int(size * 0.04))
            draw.ellipse(
                [wx - whisker_radius, whisker_y - whisker_radius,
                 wx + whisker_radius, whisker_y + whisker_radius],
                fill=nose_color
            )

    return img


def main():
    # Output directory
    output_dir = os.path.join(
        os.path.dirname(__file__),
        '../MarmotIM/Assets.xcassets/AppIcon.appiconset'
    )
    os.makedirs(output_dir, exist_ok=True)

    # Icon sizes for macOS
    sizes = [
        (16, '1x'),
        (32, '2x'),    # 16x16 @2x
        (32, '1x'),
        (64, '2x'),    # 32x32 @2x
        (128, '1x'),
        (256, '2x'),   # 128x128 @2x
        (256, '1x'),
        (512, '2x'),   # 256x256 @2x
        (512, '1x'),
        (1024, '2x'),  # 512x512 @2x
    ]

    # Generate icons at different sizes
    actual_sizes = [16, 32, 64, 128, 256, 512, 1024]

    print("Generating MarmotIM icons...")

    for pixel_size in actual_sizes:
        icon = create_marmot_icon(pixel_size)

        # Map to correct filename
        if pixel_size == 16:
            filename = 'icon_16x16.png'
        elif pixel_size == 32:
            # Save both 16@2x and 32@1x
            icon.save(os.path.join(output_dir, 'icon_16x16@2x.png'))
            filename = 'icon_32x32.png'
        elif pixel_size == 64:
            filename = 'icon_32x32@2x.png'
        elif pixel_size == 128:
            filename = 'icon_128x128.png'
        elif pixel_size == 256:
            # Save both 128@2x and 256@1x
            icon.save(os.path.join(output_dir, 'icon_128x128@2x.png'))
            filename = 'icon_256x256.png'
        elif pixel_size == 512:
            # Save both 256@2x and 512@1x
            icon.save(os.path.join(output_dir, 'icon_256x256@2x.png'))
            filename = 'icon_512x512.png'
        elif pixel_size == 1024:
            filename = 'icon_512x512@2x.png'
        else:
            continue

        icon.save(os.path.join(output_dir, filename))
        print(f"  Generated: {filename} ({pixel_size}x{pixel_size})")

    print(f"\nIcons saved to: {output_dir}")
    print("Done!")


if __name__ == '__main__':
    main()
