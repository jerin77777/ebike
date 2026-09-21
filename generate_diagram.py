import os
from PIL import Image, ImageDraw, ImageFont

def generate_diagram_image(output_filename="diagram.png"):
    # ---------------------------------------------------------
    # 1. Custom Signal Mapping Definitions (Raspberry Pi 4B)
    # ---------------------------------------------------------
    CUSTOM_MAPPINGS = {
        32: {
            "name": "HALL_SPEEDOMETER",
            "desc": "Speedometer — Hall Sensor Pulse",
            "gpio_bcm": "GPIO 12",
            "color": (5, 150, 105),      # Emerald Green
            "bg_color": (209, 250, 229),
        },
        35: {
            "name": "MODE_LINE_1",
            "desc": "Controller Mode — Line 1",
            "gpio_bcm": "GPIO 19",
            "color": (217, 119, 6),      # Warm Amber/Orange
            "bg_color": (254, 243, 199),
        },
        37: {
            "name": "MODE_LINE_2",
            "desc": "Controller Mode — Line 2",
            "gpio_bcm": "GPIO 26",
            "color": (220, 38, 38),      # Bright Red
            "bg_color": (254, 226, 226),
        },
        36: {
            "name": "INDICATOR_LEFT",
            "desc": "Turn Indicator — Left",
            "gpio_bcm": "GPIO 16",
            "color": (37, 99, 235),      # Royal Blue
            "bg_color": (219, 234, 254),
        },
        40: {
            "name": "INDICATOR_RIGHT",
            "desc": "Turn Indicator — Right",
            "gpio_bcm": "GPIO 21",
            "color": (147, 51, 234),     # Deep Purple
            "bg_color": (243, 232, 255),
        },
        22: {
            "name": "REVERSE_SW",
            "desc": "Reverse Mode Switch",
            "gpio_bcm": "GPIO 25",
            "color": (225, 29, 72),      # Rose / Pink
            "bg_color": (255, 228, 230),
        },
        23: {
            "name": "LOW_BEAM_SW",
            "desc": "Low Beam Headlight Switch",
            "gpio_bcm": "GPIO 11",
            "color": (13, 148, 136),     # Cyan / Teal
            "bg_color": (204, 251, 241),
        },
        24: {
            "name": "HIGH_BEAM_SW",
            "desc": "High Beam Headlight Switch",
            "gpio_bcm": "GPIO 8",
            "color": (2, 132, 199),      # Sky Blue
            "bg_color": (224, 242, 254),
        },
    }

    # ---------------------------------------------------------
    # 2. Raspberry Pi 4B 40-Pin Header Data Matrix
    # ---------------------------------------------------------
    PIN_DATA = [
        {"left": {"name": "3V3 power",         "pin": 1,  "type": "3V3"},
         "right": {"pin": 2,  "name": "5V power",         "type": "5V"}},
        {"left": {"name": "GPIO 2 (SDA)",      "pin": 3,  "type": "GPIO"},
         "right": {"pin": 4,  "name": "5V power",         "type": "5V"}},
        {"left": {"name": "GPIO 3 (SCL)",      "pin": 5,  "type": "GPIO"},
         "right": {"pin": 6,  "name": "Ground",           "type": "GND"}},
        {"left": {"name": "GPIO 4 (GPCLK0)",   "pin": 7,  "type": "GPIO"},
         "right": {"pin": 8,  "name": "GPIO 14 (TXD)",    "type": "GPIO"}},
        {"left": {"name": "Ground",            "pin": 9,  "type": "GND"},
         "right": {"pin": 10, "name": "GPIO 15 (RXD)",    "type": "GPIO"}},
        {"left": {"name": "GPIO 17",           "pin": 11, "type": "GPIO"},
         "right": {"pin": 12, "name": "GPIO 18 (PCM_CLK)", "type": "GPIO"}},
        {"left": {"name": "GPIO 27",           "pin": 13, "type": "GPIO"},
         "right": {"pin": 14, "name": "Ground",           "type": "GND"}},
        {"left": {"name": "GPIO 22",           "pin": 15, "type": "GPIO"},
         "right": {"pin": 16, "name": "GPIO 23",          "type": "GPIO"}},
        {"left": {"name": "3V3 power",         "pin": 17, "type": "3V3"},
         "right": {"pin": 18, "name": "GPIO 24",          "type": "GPIO"}},
        {"left": {"name": "GPIO 10 (MOSI)",   "pin": 19, "type": "GPIO"},
         "right": {"pin": 20, "name": "Ground",           "type": "GND"}},
        {"left": {"name": "GPIO 9 (MISO)",    "pin": 21, "type": "GPIO"},
         "right": {"pin": 22, "name": "GPIO 25",          "type": "GPIO"}},
        {"left": {"name": "GPIO 11 (SCLK)",   "pin": 23, "type": "GPIO"},
         "right": {"pin": 24, "name": "GPIO 8 (CE0)",     "type": "GPIO"}},
        {"left": {"name": "Ground",            "pin": 25, "type": "GND"},
         "right": {"pin": 26, "name": "GPIO 7 (CE1)",     "type": "GPIO"}},
        {"left": {"name": "GPIO 0 (ID_SD)",    "pin": 27, "type": "GPIO"},
         "right": {"pin": 28, "name": "GPIO 1 (ID_SC)",   "type": "GPIO"}},
        {"left": {"name": "GPIO 5",            "pin": 29, "type": "GPIO"},
         "right": {"pin": 30, "name": "Ground",           "type": "GND"}},
        {"left": {"name": "GPIO 6",            "pin": 31, "type": "GPIO"},
         "right": {"pin": 32, "name": "GPIO 12 (PWM0)",   "type": "GPIO"}},
        {"left": {"name": "GPIO 13 (PWM1)",   "pin": 33, "type": "GPIO"},
         "right": {"pin": 34, "name": "Ground",           "type": "GND"}},
        {"left": {"name": "GPIO 19 (PCM_FS)",  "pin": 35, "type": "GPIO"},
         "right": {"pin": 36, "name": "GPIO 16",          "type": "GPIO"}},
        {"left": {"name": "GPIO 26",           "pin": 37, "type": "GPIO"},
         "right": {"pin": 38, "name": "GPIO 20 (PCM_DIN)", "type": "GPIO"}},
        {"left": {"name": "Ground",            "pin": 39, "type": "GND"},
         "right": {"pin": 40, "name": "GPIO 21 (PCM_DOUT)","type": "GPIO"}}
    ]

    # ---------------------------------------------------------
    # 3. Canvas & Layout Dimensions
    # ---------------------------------------------------------
    col_widths = {
        "custom_signal_left": 250,
        "name_left": 240,
        "pin": 60,
        "header_gap": 16,
        "name_right": 240,
        "custom_signal_right": 250
    }

    full_table_w = (
        col_widths["custom_signal_left"] +
        col_widths["name_left"] +
        col_widths["pin"] +
        col_widths["header_gap"] +
        col_widths["pin"] +
        col_widths["name_right"] +
        col_widths["custom_signal_right"]
    )

    margin_x = 40
    canvas_width = margin_x + full_table_w + margin_x

    row_height = 38
    header_height = 110
    table_header_height = 44
    legend_height = 270

    num_rows = len(PIN_DATA)
    canvas_height = header_height + table_header_height + (num_rows * row_height) + legend_height + 40

    # Create Canvas
    image = Image.new("RGB", (canvas_width, canvas_height), (248, 250, 252))
    draw = ImageDraw.Draw(image)

    # Load Fonts
    try:
        title_font = ImageFont.truetype("arialbd.ttf", 26)
        subtitle_font = ImageFont.truetype("arial.ttf", 15)
        header_font = ImageFont.truetype("arialbd.ttf", 14)
        cell_font = ImageFont.truetype("arial.ttf", 14)
        pin_font = ImageFont.truetype("arialbd.ttf", 15)
        callout_font = ImageFont.truetype("arialbd.ttf", 13)
    except Exception:
        title_font = ImageFont.load_default()
        subtitle_font = ImageFont.load_default()
        header_font = ImageFont.load_default()
        cell_font = ImageFont.load_default()
        pin_font = ImageFont.load_default()
        callout_font = ImageFont.load_default()

    # Colors
    HEADER_BG = (15, 23, 42)          # Slate 900
    TEXT_MAIN = (15, 23, 42)          # Slate 900
    GRID_LINE = (203, 213, 225)       # Slate 300
    ROW_EVEN_BG = (255, 255, 255)     # White
    ROW_ODD_BG = (241, 245, 249)      # Slate 100

    PIN_TYPE_COLORS = {
        "3V3": {"bg": (255, 214, 0),   "text": (0, 0, 0)},       # Yellow
        "5V":  {"bg": (239, 68, 68),   "text": (255, 255, 255)}, # Red
        "GND": {"bg": (30, 41, 59),    "text": (255, 255, 255)}, # Dark Slate/Black
        "GPIO":{"bg": (34, 197, 94),   "text": (255, 255, 255)}, # Green
    }

    # Helper function to center text in a cell
    def draw_centered_text(x, y, w, h, text, font, color):
        bbox = font.getbbox(str(text)) if hasattr(font, 'getbbox') else (0, 0, font.getsize(str(text))[0], font.getsize(str(text))[1])
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        tx = x + (w - tw) / 2
        ty = y + (h - th) / 2
        draw.text((tx, ty), str(text), fill=color, font=font)

    # ---------------------------------------------------------
    # 4. Render Banner Header
    # ---------------------------------------------------------
    draw.rectangle([(0, 0), (canvas_width, 85)], fill=HEADER_BG)
    draw.text((margin_x, 18), "Raspberry Pi 4B — Hardware Pinout & Wiring Diagram", fill=(255, 255, 255), font=title_font)
    draw.text((margin_x, 52), "Custom Pin Allocation: Controller Mode, Turn Indicators, Speedometer Hall Sensor, Lights & Reverse", fill=(148, 163, 184), font=subtitle_font)

    # ---------------------------------------------------------
    # 5. Render Table Column Headers
    # ---------------------------------------------------------
    start_y = header_height

    # Calculate column X positions
    col_x = {}
    x_curr = margin_x

    col_x["custom_left"] = x_curr
    x_curr += col_widths["custom_signal_left"]

    col_x["name_left"] = x_curr
    x_curr += col_widths["name_left"]

    col_x["pin_left"] = x_curr
    x_curr += col_widths["pin"]

    col_x["gap"] = x_curr
    x_curr += col_widths["header_gap"]

    col_x["pin_right"] = x_curr
    x_curr += col_widths["pin"]

    col_x["name_right"] = x_curr
    x_curr += col_widths["name_right"]

    col_x["custom_right"] = x_curr

    # Draw Header Background
    draw.rectangle([(margin_x, start_y), (margin_x + full_table_w, start_y + table_header_height)], fill=(226, 232, 240), outline=GRID_LINE, width=1)

    # Column Headers Text
    draw_centered_text(col_x["custom_left"], start_y, col_widths["custom_signal_left"], table_header_height, "★ Custom Signal", header_font, (180, 83, 9))
    
    draw.rectangle([(col_x["name_left"], start_y), (col_x["name_left"] + col_widths["name_left"], start_y + table_header_height)], outline=GRID_LINE, width=1)
    draw_centered_text(col_x["name_left"], start_y, col_widths["name_left"], table_header_height, "Pin Function", header_font, TEXT_MAIN)

    draw.rectangle([(col_x["pin_left"], start_y), (col_x["pin_left"] + col_widths["pin"], start_y + table_header_height)], outline=GRID_LINE, width=1)
    draw_centered_text(col_x["pin_left"], start_y, col_widths["pin"], table_header_height, "Pin#", header_font, TEXT_MAIN)

    draw.rectangle([(col_x["pin_right"], start_y), (col_x["pin_right"] + col_widths["pin"], start_y + table_header_height)], outline=GRID_LINE, width=1)
    draw_centered_text(col_x["pin_right"], start_y, col_widths["pin"], table_header_height, "Pin#", header_font, TEXT_MAIN)

    draw.rectangle([(col_x["name_right"], start_y), (col_x["name_right"] + col_widths["name_right"], start_y + table_header_height)], outline=GRID_LINE, width=1)
    draw_centered_text(col_x["name_right"], start_y, col_widths["name_right"], table_header_height, "Pin Function", header_font, TEXT_MAIN)

    draw_centered_text(col_x["custom_right"], start_y, col_widths["custom_signal_right"], table_header_height, "★ Custom Signal", header_font, (180, 83, 9))

    # ---------------------------------------------------------
    # 6. Render Data Rows
    # ---------------------------------------------------------
    row_y = start_y + table_header_height

    for idx, row in enumerate(PIN_DATA):
        row_bg = ROW_EVEN_BG if idx % 2 == 0 else ROW_ODD_BG
        left_pin = row["left"]["pin"]
        right_pin = row["right"]["pin"]

        # Fill background across row
        draw.rectangle([(margin_x, row_y), (margin_x + full_table_w, row_y + row_height)], fill=row_bg)

        # ---- LEFT CUSTOM SIGNAL ----
        if left_pin in CUSTOM_MAPPINGS:
            c_info = CUSTOM_MAPPINGS[left_pin]
            cx = col_x["custom_left"]
            draw.rectangle([(cx + 4, row_y + 3), (cx + col_widths["custom_signal_left"] - 4, row_y + row_height - 3)],
                           fill=c_info["bg_color"], outline=c_info["color"], width=2)
            draw_centered_text(cx + 4, row_y + 3, col_widths["custom_signal_left"] - 8, row_height - 6,
                               f"★ {c_info['name']}", callout_font, c_info["color"])

        # ---- LEFT PIN FUNCTION ----
        nx_l = col_x["name_left"]
        nw_l = col_widths["name_left"]
        draw.rectangle([(nx_l, row_y), (nx_l + nw_l, row_y + row_height)], outline=GRID_LINE, width=1)
        draw_centered_text(nx_l, row_y, nw_l, row_height, row["left"]["name"], cell_font, TEXT_MAIN)

        # ---- LEFT PIN NUMBER ----
        pin_type_l = row["left"]["type"]
        pin_col_l = PIN_TYPE_COLORS.get(pin_type_l, PIN_TYPE_COLORS["GPIO"])

        if left_pin in CUSTOM_MAPPINGS:
            pin_bg_l = CUSTOM_MAPPINGS[left_pin]["color"]
            pin_fg_l = (255, 255, 255)
        else:
            pin_bg_l = pin_col_l["bg"]
            pin_fg_l = pin_col_l["text"]

        px_l = col_x["pin_left"]
        pw_l = col_widths["pin"]
        draw.rectangle([(px_l, row_y), (px_l + pw_l, row_y + row_height)], fill=pin_bg_l, outline=(0, 0, 0), width=1)
        draw_centered_text(px_l, row_y, pw_l, row_height, str(left_pin), pin_font, pin_fg_l)

        # ---- CENTER GAP ----
        draw.rectangle([(col_x["gap"], row_y), (col_x["gap"] + col_widths["header_gap"], row_y + row_height)], fill=(203, 213, 225))

        # ---- RIGHT PIN NUMBER ----
        pin_type_r = row["right"]["type"]
        pin_col_r = PIN_TYPE_COLORS.get(pin_type_r, PIN_TYPE_COLORS["GPIO"])

        if right_pin in CUSTOM_MAPPINGS:
            pin_bg_r = CUSTOM_MAPPINGS[right_pin]["color"]
            pin_fg_r = (255, 255, 255)
        else:
            pin_bg_r = pin_col_r["bg"]
            pin_fg_r = pin_col_r["text"]

        px_r = col_x["pin_right"]
        pw_r = col_widths["pin"]
        draw.rectangle([(px_r, row_y), (px_r + pw_r, row_y + row_height)], fill=pin_bg_r, outline=(0, 0, 0), width=1)
        draw_centered_text(px_r, row_y, pw_r, row_height, str(right_pin), pin_font, pin_fg_r)

        # ---- RIGHT PIN FUNCTION ----
        nx_r = col_x["name_right"]
        nw_r = col_widths["name_right"]
        draw.rectangle([(nx_r, row_y), (nx_r + nw_r, row_y + row_height)], outline=GRID_LINE, width=1)
        draw_centered_text(nx_r, row_y, nw_r, row_height, row["right"]["name"], cell_font, TEXT_MAIN)

        # ---- RIGHT CUSTOM SIGNAL ----
        if right_pin in CUSTOM_MAPPINGS:
            c_info = CUSTOM_MAPPINGS[right_pin]
            cx = col_x["custom_right"]
            draw.rectangle([(cx + 4, row_y + 3), (cx + col_widths["custom_signal_right"] - 4, row_y + row_height - 3)],
                           fill=c_info["bg_color"], outline=c_info["color"], width=2)
            draw_centered_text(cx + 4, row_y + 3, col_widths["custom_signal_right"] - 8, row_height - 6,
                               f"★ {c_info['name']}", callout_font, c_info["color"])

        row_y += row_height

    # ---------------------------------------------------------
    # 7. Render Legend & Custom Signal Summary Card
    # ---------------------------------------------------------
    legend_y = row_y + 30
    draw.rectangle([(margin_x, legend_y), (margin_x + full_table_w, legend_y + 240)], fill=(255, 255, 255), outline=(203, 213, 225), width=2)

    # Legend Card Header
    draw.rectangle([(margin_x, legend_y), (margin_x + full_table_w, legend_y + 36)], fill=(241, 245, 249))
    draw.text((margin_x + 15, legend_y + 9), "HARDWARE SIGNAL ASSIGNMENT LEGEND", fill=TEXT_MAIN, font=header_font)

    # Section 1: Custom Signal Connections
    leg_item_y = legend_y + 50
    col1_x = margin_x + 20
    col2_x = margin_x + full_table_w / 2 + 10

    mapped_items = list(CUSTOM_MAPPINGS.items())
    for idx, (pin_num, info) in enumerate(mapped_items):
        item_x = col1_x if idx % 2 == 0 else col2_x
        curr_item_y = leg_item_y + (idx // 2) * 32

        # Color Box
        draw.rectangle([(item_x, curr_item_y), (item_x + 18, curr_item_y + 18)], fill=info["color"], outline=(0, 0, 0), width=1)

        # Text Details
        signal_text = f"Pin {pin_num} ({info['gpio_bcm']}) — {info['name']}: {info['desc']}"
        draw.text((item_x + 26, curr_item_y + 1), signal_text, fill=TEXT_MAIN, font=cell_font)

    # Section 2: Standard Power / Ground Legend
    p_leg_y = legend_y + 190
    draw.line([(margin_x + 15, p_leg_y - 12), (margin_x + full_table_w - 15, p_leg_y - 12)], fill=GRID_LINE, width=1)

    std_types = [
        ("Power +3.3V", PIN_TYPE_COLORS["3V3"]["bg"]),
        ("Power +5.0V", PIN_TYPE_COLORS["5V"]["bg"]),
        ("Ground (GND)", PIN_TYPE_COLORS["GND"]["bg"]),
        ("General GPIO Pin", PIN_TYPE_COLORS["GPIO"]["bg"])
    ]

    p_x = margin_x + 20
    for label, bg in std_types:
        draw.rectangle([(p_x, p_leg_y), (p_x + 16, p_leg_y + 16)], fill=bg, outline=(0, 0, 0), width=1)
        draw.text((p_x + 22, p_leg_y + 1), label, fill=TEXT_MAIN, font=cell_font)
        p_x += 260

    # ---------------------------------------------------------
    # 8. Save Generated Image
    # ---------------------------------------------------------
    image.save(output_filename, "PNG", dpi=(300, 300))
    print(f"Successfully generated pinout diagram: {os.path.abspath(output_filename)}")

if __name__ == "__main__":
    generate_diagram_image()
