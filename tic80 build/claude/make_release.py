import subprocess, os, shutil, zipfile

TIC = os.environ.get('TIC80', r'C:\Program Files\tic80-v1.3-win.exe')
this_dir = os.path.dirname(os.path.abspath(__file__))
root_dir = os.path.abspath(os.path.join(this_dir, '..', '..'))
claude_dir = this_dir
release_dir = os.path.join(root_dir, 'release')

# 1. Build latest cart
print("1. Building cart...")
r = subprocess.run(['python', 'build.py'], cwd=claude_dir, capture_output=True, text=True)
if r.returncode != 0:
    print("Build failed:", r.stderr)
    exit(1)
print("Build output:", r.stdout.strip())

# 2. Export HTML via TIC-80
print("2. Exporting HTML via TIC-80...")
cmd = 'load fairy_ring.tic & export html fairy_ring alone=1 & exit'
r = subprocess.run([TIC, '--cli', f'--fs={claude_dir}', f'--cmd={cmd}'], capture_output=True, text=True)
print("TIC export STDOUT:", r.stdout.strip())

zip_path = os.path.join(claude_dir, 'fairy_ring.zip')
if not os.path.exists(zip_path):
    print("Error: fairy_ring.zip not found at", zip_path)
    exit(1)

# 3. Create release directory
os.makedirs(release_dir, exist_ok=True)

# 4. Extract to release_dir
print("3. Extracting to release directory:", release_dir)
with zipfile.ZipFile(zip_path, 'r') as zf:
    zf.extractall(release_dir)

# 5. Enhance index.html
index_html_path = os.path.join(release_dir, 'index.html')
with open(index_html_path, 'r', encoding='utf-8') as f:
    html = f.read()

# Replace title
html = html.replace('<title>fairy_ring</title>', '<title>Fairy Ring Pinball</title>')

# Add key prevention snippet so Space / Arrows / Tab don't scroll the browser page
prevent_scroll_js = """
        // Prevent default browser scrolling/actions for game control keys
        window.addEventListener('keydown', function(e) {
            if (['Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Tab'].includes(e.code) || e.keyCode === 32) {
                e.preventDefault();
            }
        }, { passive: false });
"""
if 'Prevent default browser scrolling' not in html:
    html = html.replace('document.getElementById(\'canvas\').focus()', 'document.getElementById(\'canvas\').focus()\n' + prevent_scroll_js)

with open(index_html_path, 'w', encoding='utf-8') as f:
    f.write(html)
print("Enhanced index.html with page scroll prevention and title.")

# 6. Create clean distributable zip inside release_dir as well
final_zip_path = os.path.join(release_dir, 'fairy_ring.zip')
with zipfile.ZipFile(final_zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    for filename in ['index.html', 'tic80.js', 'tic80.wasm', 'cart.tic']:
        file_to_add = os.path.join(release_dir, filename)
        if os.path.exists(file_to_add):
            zf.write(file_to_add, arcname=filename)
print("Created distributable zip at:", final_zip_path)

# Also copy standalone fairy_ring.tic into release/ for native TIC-80 players
shutil.copy(os.path.join(claude_dir, 'fairy_ring.tic'), os.path.join(release_dir, 'fairy_ring.tic'))
print("Copied standalone fairy_ring.tic to release/")

# Clean up temp fairy_ring.zip in claude_dir
if os.path.exists(zip_path):
    os.remove(zip_path)

print("Release files in", release_dir, ":")
for f in os.listdir(release_dir):
    sz = os.path.getsize(os.path.join(release_dir, f))
    print(f"  {f} ({sz:,} bytes)")
