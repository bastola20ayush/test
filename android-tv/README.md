# Android TV: FLauncher + debloat

One script connects to your Android TV over Wi‑Fi and does the following:

1. Installs [FLauncher](https://gitlab.com/flauncher/flauncher) 0.18.0 and makes it the home screen. This is the official release, and the script checks its SHA-256.
2. Turns off the stock home screen (Google TV, Android TV, Xiaomi PatchWall), the ads and recommendation rows, ambient mode, and the preinstalled apps listed in [`packages-to-remove.txt`](packages-to-remove.txt).

It works on any computer that's on the same network as the TV. If `adb` isn't installed, the script downloads Google's platform-tools.

Nothing is permanently deleted. Apps are disabled or hidden for the TV's user, so `--restore` brings everything back.

## 1. Turn on debugging on the TV

1. **Settings → System → About** (on some TVs, **Settings → Device Preferences → About**).
2. Scroll to **Android TV OS build** (or **Build**) and press OK on it **7 times** until it says you're a developer.
3. Go back to **Settings → System → Developer options** and turn on **USB debugging**. If you see **Network debugging**, turn that on too.
4. Find the TV's IP address under **Settings → Network & Internet →** your Wi‑Fi network, for example `192.168.1.50`.

## 2. Pick which apps to remove

Open `packages-to-remove.txt`. The script removes everything listed there, including YouTube, Netflix and Prime Video. Delete a line to keep that app.

Three items at the bottom are kept by default, because turning them off breaks a feature: voice search, casting from your phone, and the Play Store. Remove the `#` in front of one to turn it off as well.

## 3. Run it

**From an Android phone:** install [Termux from F-Droid](https://f-droid.org/packages/com.termux/). The Play Store version is outdated. Open it, paste this line, and change the IP address to your TV's:

```bash
pkg install -y git android-tools && git clone -b ccr-adf56627-7x1odh https://github.com/bastola20ayush/test && bash test/android-tv/tv-setup.sh 192.168.0.100
```

**From a computer:** download this folder, open a terminal in it, and run the command for your computer.

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File tv-setup.ps1 192.168.1.50
```

**macOS / Linux:**

```bash
./tv-setup.sh 192.168.1.50
```

When the TV asks **"Allow USB debugging?"**, tick **Always allow from this computer** and choose **Allow**. Then press **Home** on the remote. If the TV asks which app to use, pick **FLauncher**, then **Always**.

### If it can't connect

Newer Google TV models only offer **Wireless debugging** with a pairing code. Open it in Developer options and choose **Pair device with pairing code**. Then pair once, using the IP:port and code shown on the TV:

```
platform-tools/adb pair 192.168.1.50:37123      # use just "adb" if you installed it yourself
```

Then run the script with the IP:port shown on the main **Wireless debugging** screen, for example `./tv-setup.sh 192.168.1.50:41234`.

## Customizing FLauncher

On the FLauncher home screen, press **Up** and select the gear icon in the top-right corner. From there you can:

- Change the wallpaper (a picture or a gradient).
- Create, rename and reorder categories, and choose row or grid layout for each.
- Hide apps you don't want to see.
- Open the TV's own Android settings.

Long-press an app to move it or hide it.

## Undo

```powershell
powershell -ExecutionPolicy Bypass -File tv-setup.ps1 192.168.1.50 -Restore
```

```bash
./tv-setup.sh 192.168.1.50 --restore
```

This turns every app the script removed back on, uninstalls FLauncher, and returns you to the original home screen. The script keeps a record of what it removed for each TV in `removed-packages-<ip>.log`, so don't delete that file.

A factory reset also undoes everything.

## Keep only YouTube

After setup, `tv-simple.sh` strips the TV down to YouTube on the FLauncher home screen. It turns YouTube back on, then turns off every other app that shows on the home screen or was installed by hand. It leaves settings, HDMI input, keyboards and the Play Store alone.

```bash
bash test/android-tv/tv-simple.sh 192.168.0.100            # shows what would be turned off, changes nothing
bash test/android-tv/tv-simple.sh 192.168.0.100 --apply    # turns those off
bash test/android-tv/tv-simple.sh 192.168.0.100 --nepali-tv  # installs TiviMate and the Nepali channel list
bash test/android-tv/tv-simple.sh 192.168.0.100 --aurora    # installs Aurora Store; after that --apply also turns off the Play Store
```

`tv-setup.sh <ip> --restore` undoes all of it.
