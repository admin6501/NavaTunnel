# NavaTunnel user guide

[فارسی](USAGE.fa.md) · [Home](../README.md) · [Operations](OPERATIONS.md) · [Commands](CLI.md) · [FAQ](FAQ.md)

## Before you start

Have the public IPv4 of both servers and the service ports of your existing foreign application. For example, if an inbound listens on foreign port `8443`, include `8443`. A service port carries application traffic. An FRP control port connects FRPC to FRPS and must be different from service ports. Internal GRE addresses are allocated automatically.

Install NavaTunnel on both servers using the [installation command](../README.md#install). Run all management commands as root.

## On Iran

Open `NavaTunnel`, select **1 → 1**, then:

1. Enter a tunnel name, or press Enter for an automatic name. Enter `0` as the name to cancel.
2. Confirm Iran's public IP and enter the foreign server's public IP.
3. Enter service ports separated by commas. Choose ports that are unused by other Iran tunnels/listeners.
4. Answer `n` to loss recovery to keep FRP TCP, or `y` to select KCP/FEC.
5. Enter an unused control port, or press Enter for automatic selection.

After successful creation, open **1 → 3**, select the tunnel, then **8**. Keep the resulting command private.

## On the foreign server

Run only the generated line beginning with `NavaTunnel setup-foreign --bundle`. Do not paste the menu, descriptive text or terminal prompt. The script installs the matching GRE route and FRPC client; FRPC forwards requests to the application's local service ports.

For a **new Iran**, run its code without adding `--force`. For an **existing Iran**, use the selected foreign connection's option **6** and confirm the update, or append `--foreign-id N --force` using its actual ID from `NavaTunnel foreign-list`. If the Iran public IP changed, select that existing connection explicitly; matching tokens or internal addresses do not identify a safe replacement by themselves. Check that the code belongs to this foreign server before running it. Start a manually stopped connection before replacing its setup.

A successful setup report is followed by an application test: connect through the Iran IP and a forwarded service port. Application authentication and TLS settings must still match your inbound.

## Manage an Iran tunnel

Open **1 → 3** and choose the tunnel:

| Option | Action |
| --- | --- |
| 1 / 2 / 3 | Start / stop / restart the selected tunnel |
| 4 | Change service ports |
| 5 | Rename |
| 6 | Change foreign public IP |
| 7 | Select direct GRE or FOU |
| 8 | Show foreign connection command |
| 9 | Traffic, limit, mode and reset |
| 10 | Enable/disable loss recovery |
| 11 | Select FRP protocol |
| 12 | Set persistent MTU |
| 13 | Change FRP control port |
| 14 | Delete this tunnel |
| 15 | View/change token |
| 16 | Assign a new internal GRE /30 and print its updated connection code |
| 0 | Back |

Port, token, carrier, address and protocol changes can require the new connection command on the matching foreign server. A selection saved on Iran does not prove that the foreign side has applied it. Keep both ends coordinated. Renaming is a local label change.

FRP protocols are TCP, KCP, QUIC, WebSocket and WSS. Loss recovery selects KCP/FEC, consumes additional traffic and does not remove physical packet loss. WSS requires the existing TLS front, which the script provisions. It is separate from the GRE/FOU carrier.

For MTU, use the same value at both ends of the matching tunnel. A larger number is not automatically faster; it must fit the actual path, including encapsulation. The default is `1380`.

## Manage the foreign connection

Open **1 → 3** on the foreign server and select the Iran connection first:

| Option | Action |
| --- | --- |
| 1 / 2 / 3 | Start / stop / restart this connection |
| 4 | Show service status |
| 5 | Traffic usage, accounting mode, limit and reset |
| 6 | Apply a replacement code or select the FRP protocol |
| 7 | Set persistent MTU |
| 8 | View/change the connection token |
| 9 | Change the remote Iran public IP |
| 10 | Delete only this connection |
| 11 | Change this connection's GRE/FOU carrier |
| 12 | Show this connection's FRPC logs |
| 0 | Back |

With several connections, use the selector so changes apply only to the intended one. The original `frpc.toml` and `gre-tunnel` names remain valid for an existing first connection. Additional connections have their own service, configuration and interface; obtain their actual names from the status display rather than guessing suffixes. A manual stop survives reboot and restore; use **Start**, not **Restart**, to resume it. These controls operate on this server; they do not remotely start or stop the other endpoint.

## Add more foreign servers

Repeat **1 → 1** on Iran for each foreign server. Each gets its own GRE interface, FRPS service, control port and token. There is no fixed five-server limit. Service ports on the same Iran IP must be distinct across registered tunnels.

## Change an IP

**Iran moved:** the new public IP must already belong to the new/current server. Open **1 → 6** on Iran to update all registered tunnels. On each foreign server select the existing connection through **1 → 3**, then change its remote Iran IP with **9**, or apply the new code using **6**. For CLI replacement, explicitly include `--foreign-id N --force`. The script does not assign IP addresses to your network card.

**Foreign moved:** on each affected Iran, select that tunnel and use **6** to save the new foreign public IP. Restore the foreign configuration on the replacement, or apply the updated code there for a fresh setup. If that connection was already restored, update it through its selected menu rather than creating another copy. Move the foreign application separately too.

Moving configuration to a new machine also requires installing/restoring its files. See [backup and migration](OPERATIONS.md).

## Connect several Iran servers to one foreign server

For two Iran servers and one shared foreign application:

```text
Iran A service port 443 ── GRE/FRP A ──┐
                                     ├── Same foreign application on 443
Iran B service port 443 ── GRE/FRP B ──┘
```

1. Update NavaTunnel on all three servers and reopen the menu.
2. On **Iran A**, create a tunnel through **1 → 1**, entering the shared foreign public IP and the application's ports. Get its code through **1 → 3 → select tunnel → 8**.
3. Run that connection command on **foreign**.
4. On **Iran B**, create its own tunnel to the **same foreign IP**, using the **same service ports** if needed. Get B's code and run it on **the same foreign server** without adding `--force` or an existing connection ID.
5. On foreign, open **1 → 3**. A list identifies each Iran by name, public IP and control port. Select the connection you want to manage. **1 → 4** shows all connections.

Adding a different Iran creates another FRPC configuration/service and GRE interface. It does not replace A. The control ports can also be equal because they listen on different Iran servers. `--force` updates only the matching connection; `--foreign-id N` explicitly targets an existing connection. Independent connections are not an automatic failover or load balancer.

**Internal GRE addresses must be different across connections on foreign.** New Iran tunnels created through the menu use a public-IP-derived allocation and check locally used addresses. A collision is rejected before any existing connection is replaced. Existing Iran tunnels may both use `10.200.0.2 / 10.200.0.1`. In that case, on **Iran B**, select its tunnel and use **16** to assign a fresh pair; then run the newly printed command on foreign. A briefly interrupted B does not require changing A.

CLI equivalents on foreign:

```bash
NavaTunnel foreign-list
NavaTunnel foreign --foreign-id 2 status
NavaTunnel foreign --foreign-id 2 stop
NavaTunnel foreign --foreign-id 2 start
NavaTunnel foreign --foreign-id 2 restart
NavaTunnel foreign --foreign-id 2 logs
```

Use the actual ID from `foreign-list`. Creation accepts `--name LABEL`; updates to the same Iran require `--force`. If Iran's public IP changes, select its existing connection in the foreign menu before applying its new code, or explicitly append `--foreign-id N --force`. Reused credentials/internal addresses alone never authorize replacing a different Iran IP. On a host with multiple connections, prefer these selected commands over legacy `--foreign` shortcuts, which refer to the original client.

## Add an application protocol or inbound

Create the additional inbound in your application panel on foreign first. Add its listening port to the **full** existing service-port list on Iran through the selected tunnel's **4**; this option replaces the list, so keep the old ports too. Get the new code with **8**, then apply it through **6** of the matching selected foreign connection. Repeat for each Iran that should expose that inbound. Share the new application's client settings separately; NavaTunnel does not create users or modify subscriptions.

Changing **FRP protocol** changes the transport between FRPC and FRPS. It does not turn a VLESS/VMess/Trojan inbound into another application protocol. See [common questions](FAQ.md) and the [command reference](CLI.md).
