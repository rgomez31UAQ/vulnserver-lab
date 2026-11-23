# Guía de hardening

Cada hallazgo que produce `audit.sh`, con su corrección y su paso de
verificación. `harden.sh` automatiza la mayoría; este documento es para el
propietario que prefiere aplicar los cambios a mano y para el reporte que el
propietario entrega.

Regla general: **respalda antes de cambiar, verifica después de cambiar.**

```bash
sudo cp -a /etc/ssh/sshd_config.d/99-vulnserver.conf /root/backup-sshd.conf
sudo sshd -t && sudo systemctl reload ssh
```

## 1. SSH

**Riesgo** — la autenticación por contraseña contra una cuenta del laboratorio es
la vía de acceso inicial; el login de root amplía el radio de daño.

Corrige `/etc/ssh/sshd_config.d/99-vulnserver.conf`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers adminlab labuser
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no
```

Antes de deshabilitar las contraseñas, instala las llaves:

```bash
ssh-keygen -t ed25519 -C "lab-owner"
ssh-copy-id -i ~/.ssh/id_ed25519.pub adminlab@<host>
ssh -o PasswordAuthentication=no adminlab@<host> true   # comprueba que funciona
```

Verifica: `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowusers'`
y `sudo audit.sh --only ssh`.

Reversión: restaura el respaldo, `sshd -t`, recarga. Mantén abierta una consola
del hipervisor mientras haces esto.

## 2. Usuarios y grupos

**Riesgo** — pertenecer a un grupo administrativo convierte la cuenta sin
privilegios en root (sudo, docker y adm pueden leer archivos sensibles; docker es
equivalente a root).

```bash
sudo gpasswd -d labuser sudo
sudo gpasswd -d labuser adm
sudo gpasswd -d labuser docker
sudo passwd -l labpriv                       # la cuenta intermedia no debe iniciar sesión
sudo awk -F: '$3==0 {print $1}' /etc/passwd  # solo root
sudo awk -F: '$2=="" {print $1}' /etc/shadow # nada
```

Verifica: `id labuser` (solo su propio grupo), `passwd -S labpriv` (`L`).

## 3. Permisos de archivos

**Riesgo** — un binario SUID de root es una shell de root directa; un directorio
escribible por todos que root ejecuta equivale a acceso de root.

```bash
# Binarios SUID/SGID inesperados
sudo find /usr /bin /sbin /opt -xdev -type f \( -perm -4000 -o -perm -2000 \) -ls
sudo chmod u-s /usr/bin/find          # Escenario A
sudo chmod g-s <archivo>

# Directorios escribibles por todos
sudo find / -xdev -type d -perm -0002 ! -path '/tmp/*' ! -path '/var/tmp/*' -ls
sudo chmod o-w <dir> ; sudo chmod 0755 /opt/vulnserver/lab/perms /opt/vulnserver/lab/cron

# Línea base del directorio de estado
sudo chown root:root /opt/vulnserver /opt/vulnserver/logs
sudo chmod 0750 /opt/vulnserver/logs
sudo chmod 0700 /opt/vulnserver/backups
sudo chown root:root /opt/vulnserver/flags/root.txt && sudo chmod 0400 /opt/vulnserver/flags/root.txt
sudo chown root:labpriv /opt/vulnserver/flags/privilege.txt && sudo chmod 0640 /opt/vulnserver/flags/privilege.txt
```

Verifica con `sudo ./scripts/flags/generate_flags.sh verify` y
`sudo audit.sh --only permissions,suid`.

Nota: `/tmp` es escribible por todos por diseño; el bit sticky (`1777`) impide
borrar archivos de otros usuarios. Compruébalo: `stat -c '%a' /tmp` → `1777`.

## 4. sudo

**Riesgo** — delegar con `NOPASSWD` una utilidad que puede ejecutar comandos
(`tar`, `find`, `less`, `vim`, `python`) entrega una shell como el usuario
delegado; un ayudante ejecutado por root y escribible por ese usuario entrega
root.

Inspecciona:

```bash
sudo visudo -c
sudo grep -rE 'NOPASSWD|ALL' /etc/sudoers /etc/sudoers.d/
sudo -l -U labuser
```

Corrige:

```bash
sudo rm -f /etc/sudoers.d/vulnserver-lab-b      # Escenario B
sudo chown root:root /usr/local/bin/lab-healthcheck
sudo chmod 0755 /usr/local/bin/lab-healthcheck
sudo visudo -c
```

Principios:

- nunca delegues un comando que pueda abrir una shell o escribir un archivo;
- si un script auxiliar debe ejecutarse como root, debe ser `root:root 0755` y no
  debe leer configuración desde una ubicación escribible por el usuario;
- prefiere `sudo -u serviceuser` con una lista explícita de comandos permitidos en
  lugar de `ALL`;
- mantén `Defaults use_pty` y el registro habilitados.

Verifica: `sudo -l -U labuser` no muestra ningún comando de root;
`sudo audit.sh --only sudo`.

## 5. Inventario SUID/SGID

Mantén una línea base y compárala:

```bash
sudo find / -xdev -type f -perm -4000 2>/dev/null | sort > /root/suid-baseline.txt
# más tarde
sudo find / -xdev -type f -perm -4000 2>/dev/null | sort | diff /root/suid-baseline.txt -
```

Quita el bit a todo lo que no puedas explicar (`chmod u-s`) y luego decide si el
paquete hace falta.

## 6. cron

**Riesgo** — una tarea de root que ejecuta un script desde una ruta escribible por
el usuario es ejecución de código como root para cualquier usuario local, y de
forma programada.

```bash
ls -la /etc/cron.d /etc/cron.hourly /etc/cron.daily
sudo stat -c '%A %U:%G %n' /etc/cron.d/*
sudo rm -f /etc/cron.d/vulnserver-lab-c      # Escenario C
sudo chmod 0755 /opt/vulnserver/lab/cron
sudo chown root:root /opt/vulnserver/lab/cron/lab-cleanup.sh
sudo chmod 0755 /opt/vulnserver/lab/cron/lab-cleanup.sh
```

Reglas: los scripts de cron y cada directorio de su ruta deben ser propiedad de
root y no escribibles por otros; nunca hagas `source` de un archivo de
configuración de un directorio de usuario; si reconstruyes el laboratorio,
prefiere temporizadores de systemd con `User=` y rutas explícitas.

Verifica: `sudo ./scripts/scenarios/scenario-c.sh verify` debe fallar después del
hardening (la vulnerabilidad ya no existe) y `audit.sh --only cron` debe pasar.

## 7. Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.56.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 3000 proto tcp
sudo ufw --force enable
sudo ufw status verbose
```

Nunca uses `ufw allow 3000` sin origen. Verifica desde un host fuera del alcance
que el puerto es inalcanzable (`nc -zv <host> 3000` debe fallar).

## 8. Servicios y puertos

```bash
sudo ss -ltnp
```

Esperado en este host: `22` (SSH), `3000` (Juice Shop) y las direcciones internas
de puente de Docker. Cualquier otra cosa necesita justificación.

API de Docker: nunca debe escuchar en TCP.

```bash
sudo ss -ltnp | grep -E ':2375|:2376'    # debe estar vacío
sudo ls /etc/systemd/system/docker.service.d/ 2>/dev/null
sudo rm -f /etc/systemd/system/docker.service.d/10-vulnserver-tcp.conf
sudo systemctl daemon-reload && sudo systemctl restart docker
```

Los paneles de base de datos y de administración no deben publicarse: revisa
`docker ps --format '{{.Names}} {{.Ports}}'`.

## 9. Docker / Juice Shop

```yaml
# ya es el valor por omisión en web/docker-compose.yml
security_opt: [no-new-privileges:true]
mem_limit: 1g
restart: unless-stopped
ports: ["${LAB_BIND_ADDR}:${JUICE_SHOP_PORT}:3000"]
logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
```

Pasos de hardening:

- fija la etiqueta de la imagen (ya está) y reconstruye de forma deliberada al
  actualizar;
- nunca montes `/var/run/docker.sock` dentro de un contenedor;
- nunca uses `privileged: true`;
- enlaza el puerto publicado a la interfaz del laboratorio (`LAB_BIND_ADDR`) y
  restringe la red de origen en UFW;
- no agregues `labuser` al grupo `docker` — es equivalente a root.

```bash
cd /opt/vulnserver/web && sudo docker compose up -d --force-recreate
sudo docker inspect vulnserver-juice-shop --format '{{.HostConfig.Privileged}} {{.HostConfig.Memory}}'
```

## 10. Actualizaciones de seguridad

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y unattended-upgrades
sudo systemctl enable --now unattended-upgrades
sudo apt-get -s upgrade | grep -c '^Inst '
```

No ejecutes una actualización completa durante un ejercicio; prográmala entre
grupos.

## 11. auditd

```bash
sudo ./scripts/monitoring/setup_audit.sh apply
sudo auditctl -l | grep vulnserver
sudo ausearch -k vulnserver_flags -ts recent
```

Mantén el conjunto de reglas versionado; es parte de la cadena de evidencia.

## 12. Logs e integridad

```bash
sudo chown root:root /opt/vulnserver/logs /opt/vulnserver/logs/*
sudo chmod 0750 /opt/vulnserver/logs
sudo chmod 0640 /opt/vulnserver/logs/*
sudo chattr +a /opt/vulnserver/logs/events.log   # solo anexar (ext4)
lsattr /opt/vulnserver/logs/events.log
```

`chattr +a` impide incluso a root reescribir el historial (root todavía puede
quitar el atributo, así que es *evidencia* de manipulación, no *prueba* de
manipulación). Archiva los logs fuera del host después de cada grupo.

## 13. Matriz de verificación

| Hallazgo | Sección de auditoría | Comando que prueba la corrección |
|---|---|---|
| login de root por SSH | `ssh` | `sshd -T \| grep permitrootlogin` → `no` |
| SSH por contraseña | `ssh` | `sshd -T \| grep passwordauthentication` → `no` |
| labuser en sudo/adm/docker | `accounts` | `id labuser` |
| labpriv puede iniciar sesión | `accounts` | `passwd -S labpriv` → `L` |
| permisos de las flags | `permissions` | `generate_flags.sh verify` |
| directorios escribibles por todos | `permissions`,`cron` | `find /opt/vulnserver -type d -perm -0002` |
| SUID en find | `suid` | `stat -c '%a' /usr/bin/find` → `755` |
| delegación de sudo | `sudo` | `ls /etc/sudoers.d/vulnserver-lab-b` |
| ayudante de root escribible | `sudo` | `stat -c '%U:%G %a' /usr/local/bin/lab-healthcheck` |
| tarea de cron de root | `cron` | `ls /etc/cron.d/vulnserver-lab-c` |
| firewall inactivo | `firewall` | `ufw status` |
| API de Docker en TCP | `services` | `ss -ltnp \| grep 2375` |
| contenedor privilegiado | `docker` | `docker inspect ... Privileged` |
| reglas de auditoría faltantes | `auditd` | `auditctl -l \| grep -c vulnserver` |

## 14. Corrida final de aceptación

```bash
sudo ./harden.sh --apply --yes
sudo ./audit.sh --stdout | head -5          # se esperan 0 FAIL en las secciones del laboratorio
sudo ./scripts/scenarios/scenario-a.sh verify; echo "A exit=$?"
sudo ./scripts/scenarios/scenario-b.sh verify; echo "B exit=$?"
sudo ./scripts/scenarios/scenario-c.sh verify; echo "C exit=$?"
```

Las tres llamadas a `verify` deben terminar con código **1** (las
vulnerabilidades ya no están) y la auditoría no debe mostrar ningún FAIL en
`ssh`, `accounts`, `permissions`, `sudo`, `suid`, `cron` ni `firewall`.
