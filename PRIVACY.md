# Privacy

GifCast is built to be the opposite of the app it replaces.

## What it does

- **GIF search** goes directly to the service you pick — Giphy
  (`api.giphy.com`) or Tenor (`tenor.googleapis.com`) — using an API key *you*
  provide. Those requests contain your search terms, as any GIF app's would.
- **Sending a GIF** downloads that one GIF from its CDN (e.g. Giphy/Tenor media
  hosts) so it can be re-encoded for the badge.
- **The badge** is reached directly over Bluetooth LE. Nothing about the badge,
  its ID, or what you send is transmitted to any server.

## What it does NOT do

- No analytics or telemetry SDKs.
- No advertising SDKs.
- No crash/usage reporting to third parties.
- No account, login, or cloud sync.
- No background network activity. It only makes a request when you search or
  send.
- No collection of your contacts, location, or device identifiers.

## Data stored on device

- Your Giphy/Tenor API keys and display preferences, in the app's local
  settings (`UserDefaults`). They never leave the phone except as the API key
  header on your own search requests.

## Permissions

- **Bluetooth** — to find and talk to your badge. Used for nothing else.
- **Photos** — only if/when you pick an image from your library to send.

If you find any behavior that contradicts the above, it's a bug — please open an
issue.
