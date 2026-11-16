#!/bin/bash
# Recreates the Stalwart container with port 995 (POP3S) published as well.
# Same image, env, volumes, ports and networks; mail data lives on the mounted
# volume, so nothing is lost. The old container is kept as "stalwart-prev"
# and comes back automatically if the new one doesn't start healthy.
set -e
if docker port stalwart 995 >/dev/null 2>&1; then echo "995 already published"; exit 0; fi
docker rm -f stalwart-prev >/dev/null 2>&1 || true
ARGS=$(docker inspect stalwart | python3 -c '
import json,sys,shlex
c=json.load(sys.stdin)[0]; h=c["HostConfig"]; cfg=c["Config"]
a=["-d","--name","stalwart"]
rp=h.get("RestartPolicy",{}).get("Name")
if rp and rp!="no": a+=["--restart",rp]
for m in c["Mounts"]:
    if m["Type"]=="bind":
        opts=[o for o in (m.get("Mode") or "").split(",") if o and o not in ("ro","rw")]
        if not m.get("RW",True): opts.insert(0,"ro")
        a+=["-v",m["Source"]+":"+m["Destination"]+(":"+",".join(opts) if opts else "")]
    elif m["Type"]=="volume": a+=["-v",m["Name"]+":"+m["Destination"]]
for e in cfg.get("Env") or []:
    if not e.startswith("PATH="): a+=["-e",e]
pb=dict(h.get("PortBindings") or {})
pb.setdefault("995/tcp",[{"HostIp":"0.0.0.0","HostPort":"995"},{"HostIp":"::","HostPort":"995"}])
for port,binds in pb.items():
    for b in binds or []:
        ip=b.get("HostIp") or ""
        if ip=="::": ip="[::]"
        a+=["-p",(ip+":" if ip else "")+b["HostPort"]+":"+port]
if h.get("NetworkMode") and h["NetworkMode"] not in ("default","bridge"): a+=["--network",h["NetworkMode"]]
for cap in h.get("CapAdd") or []: a+=["--cap-add",cap]
a.append(c["Image"])
print(" ".join(shlex.quote(x) for x in a))
')
echo "new run: docker run $ARGS" | sed -E 's/(-e [A-Z_]*(PASS|SECRET|KEY|TOKEN)[A-Z_]*=)[^ ]*/\1***/g'
[ "$1" = dry ] && { echo "cmd: $(docker inspect -f '{{json .Config.Cmd}} {{json .Config.Entrypoint}}' stalwart) image-cmd: $(docker image inspect -f '{{json .Config.Cmd}} {{json .Config.Entrypoint}}' $(docker inspect -f '{{.Config.Image}}' stalwart))"; exit 0; }
docker stop stalwart >/dev/null && docker rename stalwart stalwart-prev
if eval docker run $ARGS >/dev/null; then
  docker network connect --ip 172.30.0.10 chausima-net stalwart
  for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' stalwart 2>/dev/null || echo none); [ "$s" = healthy ] && break; sleep 3; done
  echo "health: $s"
fi
if [ "$(docker inspect -f '{{.State.Running}}' stalwart 2>/dev/null)" = true ] && [ "$(curl -s -o /dev/null -w '%{http_code}' https://mail.chausima.com/jmap/session)" = 200 ]; then
  echo "OK - new container running; old one kept as stalwart-prev"
  docker port stalwart | grep 995
else
  echo "FAILED - putting the old container back"
  docker rm -f stalwart >/dev/null 2>&1 || true
  docker rename stalwart-prev stalwart && docker start stalwart >/dev/null && echo "old container restored"
fi
command -v firewall-cmd >/dev/null && { firewall-cmd -q --add-port=995/tcp --permanent 2>/dev/null; firewall-cmd -q --reload; echo "firewalld: 995 open"; } || true
