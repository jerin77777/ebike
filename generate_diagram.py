import os
from PIL import Image, ImageDraw, ImageFont

def generate_diagram_image(output_filename="diagram.png"):
    # ---------------------------------------------------------
    # 1. Custom Signal Mapping Definitions
    # ---------------------------------------------------------
    # Maps Pin Number -> Custom Signal Details
    CUSTOM_MAPPINGS = {
        35: {
            "name": "MODE_LINE_1",
            "desc": "Controller Mode — Line 1",
            "color": (217, 119, 6),      # Warm Amber/Orange
            "bg_color": (254, 243, 199),
        },
        37: {
            "name": "MODE_LINE_2",
            "desc": "Controller Mode — Line 2",
            "color": (220, 38, 38),      # Bright Red
            "bg_color": (254, 226, 226),
        },
        36: {
            "name": "INDICATOR_LEFT",
            "desc": "Turn Indicator — Left",
            "color": (37, 99, 235),      # Royal Blue
            "bg_color": (219, 234, 254),
        },
        40: {
            "name": "INDICATOR_RIGHT",
            "desc": "Turn Indicator — Right",
            "color": (147, 51, 234),     # Deep Purple
            "bg_color": (243, 232, 255),
        },
        32: {
            "name": "HALL_SPEEDOMETER",
            "desc": "Speedometer — Hall Sensor Pulse",
            "color": (5, 150, 105),      # Emerald Green
            "bg_color": (209, 250, 229),
        }
    }

    # ---------------------------------------------------------
    # 2. Complete Radxa Zero 3W 40-Pin Header Data Matrix
    # ---------------------------------------------------------
    PIN_DATA = [
        # Row 1
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "+3.3V",     "pin": 1,  "type": "3V3"},
         "right": {"pin": 2,  "f1": "+5.0V",        "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "5V"}},
        # Row 2
        {"left": {"gpio": "490", "f4": "",             "f3": "",             "f2": "I2C_EE_M3_SDA","f1": "GPIOA_14",  "pin": 3,  "type": "GPIO"},
         "right": {"pin": 4,  "f1": "+5.0V",        "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "5V"}},
        # Row 3
        {"left": {"gpio": "491", "f4": "",             "f3": "",             "f2": "I2C_EE_M3_SCL","f1": "GPIOA_15",  "pin": 5,  "type": "GPIO"},
         "right": {"pin": 6,  "f1": "GND",          "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "GND"}},
        # Row 4
        {"left": {"gpio": "415", "f4": "I2C_AO_S0_SDA","f3": "UART_AO_B_RX", "f2": "I2C_AO_M0_SDA","f1": "GPIOAO_3",   "pin": 7,  "type": "GPIO"},
         "right": {"pin": 8,  "f1": "GPIOAO_0",     "f2": "UART_AO_A_TXD","f3": "",             "f4": "",          "gpio": "412", "type": "GPIO"}},
        # Row 5
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "GND",       "pin": 9,  "type": "GND"},
         "right": {"pin": 10, "f1": "GPIOAO_1",     "f2": "UART_AO_A_RXD","f3": "",             "f4": "",          "gpio": "413", "type": "GPIO"}},
        # Row 6
        {"left": {"gpio": "414", "f4": "I2C_AO_S0_SCL","f3": "UART_AO_B_TX", "f2": "I2C_AO_M0_SCL","f1": "GPIOAO_2",   "pin": 11, "type": "GPIO"},
         "right": {"pin": 12, "f1": "GPIOX_9",      "f2": "SPI_A_MISO",   "f3": "TDMA_D0",      "f4": "",          "gpio": "501", "type": "GPIO"}},
        # Row 7
        {"left": {"gpio": "503", "f4": "TDMA_SCLK",    "f3": "I2C_EE_M1_SCL","f2": "SPI_A_SCLK",   "f1": "GPIOX_11",  "pin": 13, "type": "GPIO"},
         "right": {"pin": 14, "f1": "GND",          "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "GND"}},
        # Row 8
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "SARADC_CH1","pin": 15, "type": "ADC"},
         "right": {"pin": 16, "f1": "GPIOX_10",     "f2": "SPI_A_SS0",    "f3": "I2C_EE_M1_SDA","f4": "TDMA_FS",   "gpio": "502", "type": "GPIO"}},
        # Row 9
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "+3.3V",     "pin": 17, "type": "3V3"},
         "right": {"pin": 18, "f1": "GPIOX_8",      "f2": "SPI_A_MOSI",   "f3": "PWM_C",        "f4": "TDMA_D1",   "gpio": "500", "type": "GPIO"}},
        # Row 10
        {"left": {"gpio": "447", "f4": "",             "f3": "SPI_B_MOSI",   "f2": "UART_EE_C_RTS","f1": "GPIOH_4",   "pin": 19, "type": "GPIO"},
         "right": {"pin": 20, "f1": "GND",          "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "GND"}},
        # Row 11
        {"left": {"gpio": "448", "f4": "PWM_F",        "f3": "SPI_B_MISO",   "f2": "UART_EE_C_CTS","f1": "GPIOH_5",   "pin": 21, "type": "GPIO"},
         "right": {"pin": 22, "f1": "GPIOC_7",      "f2": "-",            "f3": "",             "f4": "",          "gpio": "475", "type": "GPIO"}},
        # Row 12
        {"left": {"gpio": "450", "f4": "I2C_EE_M1_SCL","f3": "SPI_B_SCLK",   "f2": "UART_EE_C_TX", "f1": "GPIOH_7",   "pin": 23, "type": "GPIO"},
         "right": {"pin": 24, "f1": "GPIOH_6",      "f2": "UART_EE_C_RX", "f3": "SPI_B_SS0",    "f4": "I2C_EE_M1_SDA","gpio": "449", "type": "GPIO"}},
        # Row 13
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "GND",       "pin": 25, "type": "GND"},
         "right": {"pin": 26, "f1": "SARADC_CH2",   "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "ADC"}},
        # Row 14
        {"left": {"gpio": "415", "f4": "I2C_AO_S0_SDA","f3": "UART_AO_B_RX", "f2": "I2C_AO_M0_SDA","f1": "GPIOAO_3",   "pin": 27, "type": "GPIO"},
         "right": {"pin": 28, "f1": "GPIOAO_2",     "f2": "I2C_AO_M0_SCL","f3": "UART_AO_B_TX", "f4": "I2C_AO_S0_SCL","gpio": "414", "type": "GPIO"}},
        # Row 15
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "NC",        "pin": 29, "type": "NC"},
         "right": {"pin": 30, "f1": "GND",          "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "GND"}},
        # Row 16
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "NC",        "pin": 31, "type": "NC"},
         "right": {"pin": 32, "f1": "GPIOAO_4",     "f2": "PWMAO_C",      "f3": "",             "f4": "",          "gpio": "416", "type": "GPIO"}},
        # Row 17
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "NC",        "pin": 33, "type": "NC"},
         "right": {"pin": 34, "f1": "GND",          "f2": "",             "f3": "",             "f4": "",          "gpio": "", "type": "GND"}},
        # Row 18
        {"left": {"gpio": "420", "f4": "",             "f3": "",             "f2": "UART_AO_B_TX", "f1": "GPIOAO_8",   "pin": 35, "type": "GPIO"},
         "right": {"pin": 36, "f1": "GPIOH_8",      "f2": "-",            "f3": "",             "f4": "",          "gpio": "451", "type": "GPIO"}},
        # Row 19
        {"left": {"gpio": "421", "f4": "",             "f3": "",             "f2": "UART_AO_B_RX", "f1": "GPIOAO_9",   "pin": 37, "type": "GPIO"},
         "right": {"pin": 38, "f1": "GPIOAO_10",    "f2": "PWMAO_D",      "f3": "",             "f4": "",          "gpio": "422", "type": "GPIO"}},
        # Row 20
        {"left": {"gpio": "",    "f4": "",             "f3": "",             "f2": "",             "f1": "GND",       "pin": 39, "type": "GND"},
         "right": {"pin": 40, "f1": "GPIOAO_11",    "f2": "PWMAO_A",      "f3": "",             "f4": "",          "gpio": "423", "type": "GPIO"}}
    ]

    # ---------------------------------------------------------
    # 3. Canvas & Layout Dimensions (Strict Row & Column Logic)
    # ---------------------------------------------------------
    col_widths = {
        "custom_signal_left": 230,
        "gpio": 80,
        "f4": 125,
        "f3": 125,
        "f2": 125,
        "f1": 110,
        "pin": 55,
        "header_gap": 12,
        "custom_signal_right": 230
    }

    # Left grid section width
    left_grid_w = col_widths["gpio"] + col_widths["f4"] + col_widths["f3"] + col_widths["f2"] + col_widths["f1"] + col_widths["pin"]
    right_grid_w = col_widths["pin"] + col_widths["f1"] + col_widths["f2"] + col_widths["f3"] + col_widths["f4"] + col_widths["gpio"]
    
    table_core_w = left_grid_w + col_widths["header_gap"] + right_grid_w
    full_table_w = col_widths["custom_signal_left"] + table_core_w + col_widths["custom_signal_right"]

    margin_x = 40
    canvas_width = margin_x + full_table_w + margin_x

    row_height = 36
    header_height = 110
    table_header_height = 42
    legend_height = 240
    
    num_rows = len(PIN_DATA)
    canvas_height = header_height + table_header_height + (num_rows * row_height) + legend_height + 40

    # Create Canvas
    image = Image.new("RGB", (canvas_width, canvas_height), (248, 250, 252))
    draw = ImageDraw.Draw(image)

    # Load Fonts
    try:
        title_font = ImageFont.truetype("arialbd.ttf", 26)
        subtitle_font = ImageFont.truetype("arial.ttf", 15)
        header_font = ImageFont.truetype("arialbd.ttf", 13)
        cell_font = ImageFont.truetype("arial.ttf", 13)
        pin_font = ImageFont.truetype("arialbd.ttf", 14)
        callout_font = ImageFont.truetype("arialbd.ttf", 12)
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
        "ADC": {"bg": (34, 197, 94),   "text": (255, 255, 255)}, # Green
        "NC":  {"bg": (203, 213, 225), "text": (100, 116, 139)}   # Light Grey
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
    draw.text((margin_x, 18), "Radxa Zero 3W — Hardware Pinout & Wiring Diagram", fill=(255, 255, 255), font=title_font)
    draw.text((margin_x, 52), "Custom Pin Allocation: Controller Mode (2 lines), Indicators (2 lines) & Speedometer Hall Sensor (1 line)", fill=(148, 163, 184), font=subtitle_font)

    # ---------------------------------------------------------
    # 5. Render Table Column Headers
    # ---------------------------------------------------------
    start_y = header_height
    
    # Header Column Layout
    col_x_map = {}
    x_curr = margin_x
    
    col_x_map["custom_left"] = x_curr
    x_curr += col_widths["custom_signal_left"]

    columns_left = [
        ("gpio_left", "GPIO number", col_widths["gpio"]),
        ("f4_left",   "Function4",   col_widths["f4"]),
        ("f3_left",   "Function3",   col_widths["f3"]),
        ("f2_left",   "Function2",   col_widths["f2"]),
        ("f1_left",   "Function1",   col_widths["f1"]),
        ("pin_left",  "Pin#",        col_widths["pin"])
    ]

    for key, name, w in columns_left:
        col_x_map[key] = x_curr
        x_curr += w

    col_x_map["gap"] = x_curr
    x_curr += col_widths["header_gap"]

    columns_right = [
        ("pin_right",  "Pin#",        col_widths["pin"]),
        ("f1_right",   "Function1",   col_widths["f1"]),
        ("f2_right",   "Function2",   col_widths["f2"]),
        ("f3_right",   "Function3",   col_widths["f3"]),
        ("f4_right",   "Function4",   col_widths["f4"]),
        ("gpio_right", "GPIO number", col_widths["gpio"])
    ]

    for key, name, w in columns_right:
        col_x_map[key] = x_curr
        x_curr += w

    col_x_map["custom_right"] = x_curr

    # Draw Header Background
    draw.rectangle([(margin_x, start_y), (margin_x + full_table_w, start_y + table_header_height)], fill=(226, 232, 240), outline=GRID_LINE, width=1)

    # Custom Signal Left Header
    draw_centered_text(col_x_map["custom_left"], start_y, col_widths["custom_signal_left"], table_header_height, "★ Custom Signal", header_font, (180, 83, 9))

    # Core Pin Headers
    for key, name, w in columns_left:
        draw.rectangle([(col_x_map[key], start_y), (col_x_map[key] + w, start_y + table_header_height)], outline=GRID_LINE, width=1)
        draw_centered_text(col_x_map[key], start_y, w, table_header_height, name, header_font, TEXT_MAIN)

    for key, name, w in columns_right:
        draw.rectangle([(col_x_map[key], start_y), (col_x_map[key] + w, start_y + table_header_height)], outline=GRID_LINE, width=1)
        draw_centered_text(col_x_map[key], start_y, w, table_header_height, name, header_font, TEXT_MAIN)

    # Custom Signal Right Header
    draw_centered_text(col_x_map["custom_right"], start_y, col_widths["custom_signal_right"], table_header_height, "★ Custom Signal", header_font, (180, 83, 9))

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

        # ---- LEFT CUSTOM SIGNAL COLUMN ----
        if left_pin in CUSTOM_MAPPINGS:
            c_info = CUSTOM_MAPPINGS[left_pin]
            cx = col_x_map["custom_left"]
            draw.rectangle([(cx + 4, row_y + 3), (cx + col_widths["custom_signal_left"] - 4, row_y + row_height - 3)],
                           fill=c_info["bg_color"], outline=c_info["color"], width=2)
            draw_centered_text(cx + 4, row_y + 3, col_widths["custom_signal_left"] - 8, row_height - 6,
                               f"★ {c_info['name']}", callout_font, c_info["color"])

        # ---- LEFT PIN DATA CELLS ----
        left_cells = [
            ("gpio_left", row["left"]["gpio"], col_widths["gpio"]),
            ("f4_left",   row["left"]["f4"],   col_widths["f4"]),
            ("f3_left",   row["left"]["f3"],   col_widths["f3"]),
            ("f2_left",   row["left"]["f2"],   col_widths["f2"]),
            ("f1_left",   row["left"]["f1"],   col_widths["f1"]),
        ]

        for key, val, w in left_cells:
            draw.rectangle([(col_x_map[key], row_y), (col_x_map[key] + w, row_y + row_height)], outline=GRID_LINE, width=1)
            draw_centered_text(col_x_map[key], row_y, w, row_height, val, cell_font, TEXT_MAIN)

        # LEFT PIN NUMBER CELL
        pin_type_l = row["left"]["type"]
        pin_col_l = PIN_TYPE_COLORS.get(pin_type_l, PIN_TYPE_COLORS["GPIO"])

        if left_pin in CUSTOM_MAPPINGS:
            pin_bg = CUSTOM_MAPPINGS[left_pin]["color"]
            pin_fg = (255, 255, 255)
        else:
            pin_bg = pin_col_l["bg"]
            pin_fg = pin_col_l["text"]

        px_l = col_x_map["pin_left"]
        pw_l = col_widths["pin"]
        draw.rectangle([(px_l, row_y), (px_l + pw_l, row_y + row_height)], fill=pin_bg, outline=(0, 0, 0), width=1)
        draw_centered_text(px_l, row_y, pw_l, row_height, str(left_pin), pin_font, pin_fg)

        # ---- CENTER HEADER GAP ----
        draw.rectangle([(col_x_map["gap"], row_y), (col_x_map["gap"] + col_widths["header_gap"], row_y + row_height)], fill=(203, 213, 225))

        # ---- RIGHT PIN NUMBER CELL ----
        pin_type_r = row["right"]["type"]
        pin_col_r = PIN_TYPE_COLORS.get(pin_type_r, PIN_TYPE_COLORS["GPIO"])

        if right_pin in CUSTOM_MAPPINGS:
            pin_bg_r = CUSTOM_MAPPINGS[right_pin]["color"]
            pin_fg_r = (255, 255, 255)
        else:
            pin_bg_r = pin_col_r["bg"]
            pin_fg_r = pin_col_r["text"]

        px_r = col_x_map["pin_right"]
        pw_r = col_widths["pin"]
        draw.rectangle([(px_r, row_y), (px_r + pw_r, row_y + row_height)], fill=pin_bg_r, outline=(0, 0, 0), width=1)
        draw_centered_text(px_r, row_y, pw_r, row_height, str(right_pin), pin_font, pin_fg_r)

        # ---- RIGHT PIN DATA CELLS ----
        right_cells = [
            ("f1_right",   row["right"]["f1"],   col_widths["f1"]),
            ("f2_right",   row["right"]["f2"],   col_widths["f2"]),
            ("f3_right",   row["right"]["f3"],   col_widths["f3"]),
            ("f4_right",   row["right"]["f4"],   col_widths["f4"]),
            ("gpio_right", row["right"]["gpio"], col_widths["gpio"]),
        ]

        for key, val, w in right_cells:
            draw.rectangle([(col_x_map[key], row_y), (col_x_map[key] + w, row_y + row_height)], outline=GRID_LINE, width=1)
            draw_centered_text(col_x_map[key], row_y, w, row_height, val, cell_font, TEXT_MAIN)

        # ---- RIGHT CUSTOM SIGNAL COLUMN ----
        if right_pin in CUSTOM_MAPPINGS:
            c_info = CUSTOM_MAPPINGS[right_pin]
            cx = col_x_map["custom_right"]
            draw.rectangle([(cx + 4, row_y + 3), (cx + col_widths["custom_signal_right"] - 4, row_y + row_height - 3)],
                           fill=c_info["bg_color"], outline=c_info["color"], width=2)
            draw_centered_text(cx + 4, row_y + 3, col_widths["custom_signal_right"] - 8, row_height - 6,
                               f"★ {c_info['name']}", callout_font, c_info["color"])

        # Advance Y for next row
        row_y += row_height

    # ---------------------------------------------------------
    # 7. Render Legend & Custom Signal Summary Card
    # ---------------------------------------------------------
    legend_y = row_y + 30
    draw.rectangle([(margin_x, legend_y), (margin_x + full_table_w, legend_y + 210)], fill=(255, 255, 255), outline=(203, 213, 225), width=2)
    
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
        
        # Details Text
        # Find Linux GPIO number
        gpio_id = ""
        for r in PIN_DATA:
            if r["left"]["pin"] == pin_num:
                gpio_id = f" (GPIO {r['left']['gpio']})" if r['left']['gpio'] else ""
            elif r["right"]["pin"] == pin_num:
                gpio_id = f" (GPIO {r['right']['gpio']})" if r['right']['gpio'] else ""

        signal_text = f"Pin {pin_num}{gpio_id} — {info['name']}: {info['desc']}"
        draw.text((item_x + 26, curr_item_y + 1), signal_text, fill=TEXT_MAIN, font=cell_font)

    # Section 2: Standard Power / Ground Legend
    p_leg_y = legend_y + 160
    draw.line([(margin_x + 15, p_leg_y - 12), (margin_x + full_table_w - 15, p_leg_y - 12)], fill=GRID_LINE, width=1)
    
    std_types = [
        ("Power +3.3V", PIN_TYPE_COLORS["3V3"]["bg"]),
        ("Power +5.0V", PIN_TYPE_COLORS["5V"]["bg"]),
        ("Ground (GND)", PIN_TYPE_COLORS["GND"]["bg"]),
        ("General GPIO / Peripheral Pin", PIN_TYPE_COLORS["GPIO"]["bg"])
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
