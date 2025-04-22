# immich-monitor
Helper script that aids with `immich` container suspend and resume.

Currently `immich` likes to keep my NAS disks awake by using `postgres` to synchronize different processes.

The following `*.sh` is meant to be used to auto-start at boot, and then it will opportunistically suspend the associated containers after an idle period. It will then monitor for incoming `TCP` port `2283` connections to resume operation.

If everything is working, you should see messages such as:

```
Omar@NAS:/docker/immich-app$ dmesg | grep immich
[  121.159874] immich-monitor: [INFO] immich containers: looker
[  523.072802] immich-monitor: [INFO] immich containers: freeze
[  964.296959] immich-monitor: [INFO] immich containers: resume
```
