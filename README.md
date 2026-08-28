# Minecraft Bedrock dedicated server

Docker image for the Minecraft Bedrock Dedicated Server, based on Arch Linux.

This is a standalone image. It is derived from [binhex/arch-minecraftbedrockserver](https://github.com/binhex/arch-minecraftbedrockserver) but does not use binhex base images, helper scripts, or reusable workflows.

Images are published to the GitHub Container Registry:

```text
ghcr.io/d1vanloon/minecraftbedrockserver
```

Tags follow the Bedrock version from [EndstoneMC/bedrock-server-data](https://github.com/EndstoneMC/bedrock-server-data) (`1.26.45`, `1.26`, and `latest`).

## Usage

```bash
docker run -d \
    --net="bridge" \
    --name=<container name> \
    -p <host port>:8222/tcp \
    -p <host port>:19132/tcp \
    -p <host port>:19132/udp \
    -p <host port>:19133/tcp \
    -p <host port>:19133/udp \
    -v <path for config files>:/config \
    -v /etc/localtime:/etc/localtime:ro \
    -e CREATE_BACKUP_HOURS=<frequency of world backups in hours> \
    -e PURGE_BACKUP_DAYS=<specify oldest world backups to keep in days> \
    -e ENABLE_WEBUI_CONSOLE=<yes|no> \
    -e ENABLE_WEBUI_AUTH=<yes|no> \
    -e WEBUI_USER=<specify webui username> \
    -e WEBUI_PASS=<specify webui password> \
    -e WEBUI_CONSOLE_TITLE=<specify webui console title> \
    -e STARTUP_CMD=<minecraft console command to execute on startup> \
    -e HEALTHCHECK_COMMAND=<command> \
    -e UMASK=<umask for created files> \
    -e PUID=<uid for user> \
    -e PGID=<gid for user> \
    ghcr.io/d1vanloon/minecraftbedrockserver
```

Replace values in `<>` with your own.

## Example

```bash
docker run -d \
    --net="bridge" \
    --name=minecraftbedrockserver \
    -p 8222:8222/tcp \
    -p 19132:19132/tcp \
    -p 19132:19132/udp \
    -p 19133:19133/tcp \
    -p 19133:19133/udp \
    -v /apps/docker/minecraftbedrockserver:/config \
    -v /etc/localtime:/etc/localtime:ro \
    -e CREATE_BACKUP_HOURS=12 \
    -e PURGE_BACKUP_DAYS=14 \
    -e ENABLE_WEBUI_CONSOLE=yes \
    -e ENABLE_WEBUI_AUTH=yes \
    -e WEBUI_USER=admin \
    -e WEBUI_PASS=minecraft \
    -e WEBUI_CONSOLE_TITLE='Minecraft Bedrock' \
    -e STARTUP_CMD='gamerule showcoordinates true' \
    -e UMASK=000 \
    -e PUID=0 \
    -e PGID=0 \
    ghcr.io/d1vanloon/minecraftbedrockserver
```

## Access the Minecraft server console

Requires `-e ENABLE_WEBUI_CONSOLE=yes`.

Open `http://<host>:8222`.

## Notes

If you do not want world backups or purging of backups, set `CREATE_BACKUP_HOURS` and/or `PURGE_BACKUP_DAYS` to `0`.

User ID (`PUID`) and group ID (`PGID`) can be found with:

```bash
id <username>
```

## Builds

GitHub Actions builds `linux/amd64` images and pushes them to this repository's package feed.

- Push to `master` / `main`, or a version tag, runs `workflow-docker-release`.
- `workflow-docker-manual` builds a named test tag without moving `latest`.
- `check-bedrock-release` runs hourly, reads `versions.json` from EndstoneMC/bedrock-server-data, and starts a release build when a new stable Bedrock version is not already on GHCR.

A local build with no extra args resolves the current stable download during `docker build`.

## License

GPLv3. Runtime scripts and layout follow the binhex image. Minecraft Bedrock Dedicated Server is property of Mojang/Microsoft and is downloaded from Mojang at build time.
