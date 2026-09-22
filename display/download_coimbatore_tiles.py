import os
import math
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# Coimbatore bounding box:
# Covers Kovaipudur to Thudiyalur, Perur to Coimbatore Airport & Codissia,
# Gandhipuram, RS Puram, Peelamedu, Singanallur, Ukkadam, Saravanampatti IT corridor.
MIN_LAT = 10.90
MAX_LAT = 11.12
MIN_LON = 76.85
MAX_LON = 77.08

ZOOM_LEVELS = range(10, 16) # 10 to 15 inclusive

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "assets", "tiles")

def deg2num(lat_deg, lon_deg, zoom):
    lat_rad = math.radians(lat_deg)
    n = 2.0 ** zoom
    xtile = int((lon_deg + 180.0) / 360.0 * n)
    ytile = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return (xtile, ytile)

def get_tiles_for_bounds(min_lat, max_lat, min_lon, max_lon, zoom):
    x1, y1 = deg2num(max_lat, min_lon, zoom)
    x2, y2 = deg2num(min_lat, max_lon, zoom)
    min_x, max_x = min(x1, x2), max(x1, x2)
    min_y, max_y = min(y1, y2), max(y1, y2)
    
    tiles = []
    for x in range(min_x, max_x + 1):
        for y in range(min_y, max_y + 1):
            tiles.append((zoom, x, y))
    return tiles

def download_tile(tile, output_dir, retries=3):
    z, x, y = tile
    # Flat filename for direct inclusion in Flutter assets/tiles/
    filename = f"{z}_{x}_{y}.png"
    filepath = os.path.join(output_dir, filename)
    
    if os.path.exists(filepath) and os.path.getsize(filepath) > 500:
        return True, tile, "cached"

    url = f"https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    headers = {
        "User-Agent": "EBikeCoimbatoreOfflineMapDownloader/1.0 (offline-bike-display; jerin)"
    }
    req = urllib.request.Request(url, headers=headers)
    
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=12) as response:
                if response.status == 200:
                    data = response.read()
                    with open(filepath, "wb") as f:
                        f.write(data)
                    return True, tile, "downloaded"
                else:
                    time.sleep(1.0)
        except Exception as e:
            if attempt == retries - 1:
                return False, tile, str(e)
            time.sleep(1.0 * (attempt + 1))
            
    return False, tile, "failed"

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    all_tiles = []
    
    for z in ZOOM_LEVELS:
        tiles = get_tiles_for_bounds(MIN_LAT, MAX_LAT, MIN_LON, MAX_LON, z)
        all_tiles.extend(tiles)
        print(f"Zoom {z}: {len(tiles)} tiles")
        
    print(f"\nTotal Coimbatore tiles to download: {len(all_tiles)}")
    print(f"Destination: {OUTPUT_DIR}\n")
    
    start_time = time.time()
    successful = 0
    failed = 0
    cached = 0
    
    # Use modest worker pool to respect OpenStreetMap usage policy
    with ThreadPoolExecutor(max_workers=5) as executor:
        future_to_tile = {executor.submit(download_tile, tile, OUTPUT_DIR): tile for tile in all_tiles}
        
        for idx, future in enumerate(as_completed(future_to_tile), 1):
            success, tile, status = future.result()
            if success:
                successful += 1
                if status == "cached":
                    cached += 1
            else:
                failed += 1
                print(f"Failed to download tile {tile}: {status}")
                
            if idx % 50 == 0 or idx == len(all_tiles):
                elapsed = time.time() - start_time
                print(f"Progress: {idx}/{len(all_tiles)} tiles ({successful} ok, {cached} cached, {failed} err) in {elapsed:.1f}s")
                
    total_time = time.time() - start_time
    total_size = sum(os.path.getsize(os.path.join(OUTPUT_DIR, f)) for f in os.listdir(OUTPUT_DIR) if f.endswith(".png"))
    
    print("\n--- Summary ---")
    print(f"Finished in: {total_time:.1f} seconds")
    print(f"Successfully available: {successful}/{len(all_tiles)}")
    print(f"Total offline map size: {total_size / (1024 * 1024):.2f} MB")
    
    if failed > 0:
        print(f"Warning: {failed} tiles failed to download.")
    else:
        print("All Coimbatore tiles are ready for offline use!")

if __name__ == "__main__":
    main()
