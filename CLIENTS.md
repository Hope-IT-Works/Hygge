# Setting up clients to use Hygge

This guide shows how to point your devices at your Hygge/Technitium DNS server. Replace `<HYGGE_IP>` below with the LAN IP address of the machine running the Hygge Docker stack (**not** `127.0.0.1`, unless you're configuring that same machine).

## Recommended: configure it once at the router (DHCP)

Setting the DNS server on your router hands it out to every device on the network automatically — no per-device setup, and new devices are covered as soon as they join.

1. Log into your router's admin interface (commonly `http://192.168.0.1` or `http://192.168.1.1` — check the label on the router if unsure).
2. Find the DNS settings, usually under **WAN**, **LAN**, or **DHCP Server** settings (naming varies by vendor).
3. Set the **Primary DNS** to `<HYGGE_IP>`. Leave the secondary DNS empty, or also point it at `<HYGGE_IP>` — setting it to a public resolver as a fallback defeats the purpose of ad-blocking/DNSSEC validation, since some devices will silently prefer whichever answers first.
4. Save and reboot the router if prompted. Existing devices may need to renew their DHCP lease (reconnect to Wi-Fi, or reboot) to pick up the new DNS server.

If your router doesn't allow changing DNS settings, configure each device individually using the instructions below.

## Windows 10 / 11

1. Open **Settings → Network & Internet → Wi-Fi** (or **Ethernet**) → select your active connection.
2. Under **DNS server assignment**, click **Edit**.
3. Switch from **Automatic (DHCP)** to **Manual**, enable **IPv4**.
4. Set **Preferred DNS** to `<HYGGE_IP>`. Leave **Alternate DNS** empty.
5. Save.

Alternatively, via PowerShell (run as Administrator):

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses ("<HYGGE_IP>")
```

## macOS

1. Open **System Settings → Wi-Fi** (or **Network**) → select your active connection → **Details…** (or the (i) icon).
2. Go to the **DNS** tab.
3. Remove any existing entries and add `<HYGGE_IP>`.
4. Click **OK** / **Apply**.

## Linux

The exact method depends on your network manager:

**NetworkManager (most desktop distros):**

```sh
nmcli connection modify "<connection-name>" ipv4.dns "<HYGGE_IP>" ipv4.ignore-auto-dns yes
nmcli connection up "<connection-name>"
```

(List connection names with `nmcli connection show`.)

**systemd-resolved:**

```sh
sudo resolvectl dns <interface> <HYGGE_IP>
```

**Static `/etc/resolv.conf`** (only if nothing manages it automatically):

```
nameserver <HYGGE_IP>
```

## Android

1. Open **Settings → Network & Internet → Internet** → tap the gear icon next to your connected Wi-Fi network.
2. Tap **Edit** (or the pencil icon) → expand **Advanced options**.
3. Set **IP settings** to **Static**.
4. Set **DNS 1** to `<HYGGE_IP>`. Leave **DNS 2** empty, or set it to `<HYGGE_IP>` as well.
5. Save.

Note: newer Android versions also have a **Private DNS** setting (Settings → Network & Internet → Private DNS) which uses DNS-over-TLS to a hostname instead — leave that on **Automatic** or **Off**, since Hygge doesn't expose DNS-over-TLS by default and Private DNS would otherwise bypass the manual DNS server above entirely.

## iOS / iPadOS

1. Open **Settings → Wi-Fi** → tap the (i) icon next to your connected network.
2. Tap **Configure DNS** → switch to **Manual**.
3. Remove any existing servers and add `<HYGGE_IP>`.
4. Tap **Save**.

## Verifying it works

After configuring a device, confirm it's actually using Hygge:

- Visit the Technitium web console's **Dashboard** and check that query counts increase when you browse from that device.
- Or, from a terminal on the device (where available), resolve a domain and check the response comes from your server, e.g.:

  ```sh
  nslookup example.com <HYGGE_IP>
  ```
