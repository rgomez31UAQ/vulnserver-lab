# Solución de problemas

## SSH

**Conexión rechazada**
```bash
sudo systemctl status ssh
sudo sshd -t                 # ¿error de sintaxis en algún drop-in?
sudo ss -ltnp | grep :22
sudo ufw status              # ¿está permitida tu red de origen?
```
Si un drop-in rompió sshd, elimínalo y recarga:
`sudo rm /etc/ssh/sshd_config.d/99-vulnserver.conf && sudo systemctl restart ssh`.

**Permission denied (publickey,password)**
`AllowUsers` solo permite a `adminlab` y `labuser`. Confirma la cuenta:
`sudo ./scripts/users/create_users.sh status`, y luego restablece la contraseña
del laboratorio: `sudo passwd labuser`.

**Quedaste fuera después del hardening**
Usa la consola del hipervisor y luego:
```bash
sudo rm -f /etc/ssh/sshd_config.d/99-vulnserver.conf
sudo systemctl restart ssh
```
Por esto `harden.sh` pregunta antes de deshabilitar la autenticación por
contraseña.

## Cuentas

**`useradd: group labpriv exists`**
Corregido en `scripts/users/create_users.sh` (el grupo se crea primero y se
reutiliza). Si lo ves en una copia anterior, ejecuta
`sudo ./scripts/users/create_users.sh create` de nuevo después de actualizar.

**`labpriv` puede iniciar sesión**
```bash
sudo passwd -l labpriv
sudo usermod --password '!' labpriv
passwd -S labpriv        # debe empezar con L
```

## Flags

**Faltan las flags después de instalar**
```bash
sudo ./scripts/flags/generate_flags.sh generate --force
sudo ./scripts/flags/generate_flags.sh verify
```

**Un estudiante puede leer `root.txt`**
El modelo de permisos está roto. `sudo ./scripts/flags/generate_flags.sh verify`
muestra la desviación; corrígela con
`sudo ./harden.sh --apply --only permissions`. Revisa también si hay copias:
`sudo grep -r 'VS{' /home /tmp /opt/vulnserver/lab 2>/dev/null`. `reset-lab.sh`
rota los valores, así que las copias filtradas dejan de servir.

**Flags rastreadas por git**
```bash
git rm --cached flags/user.txt flags/privilege.txt flags/root.txt
```
`.gitignore` ya excluye el directorio; nunca hagas commit de flags generadas.

## Docker / Juice Shop

**`Cannot connect to the Docker daemon`**
```bash
sudo systemctl status docker
sudo systemctl enable --now docker
sudo docker info
```

**Puerto ya en uso**
```bash
sudo ss -ltnp | grep :3000
sudo JUICE_SHOP_PORT=3001 ./install.sh --no-firewall   # o detén el otro servicio
```

**El contenedor arranca y se apaga**
```bash
cd /opt/vulnserver/web
sudo docker compose logs --tail 100 juice-shop
sudo docker compose ps
```
La causa habitual es poca memoria en una VM de 1 GB; dale 2 GB a la VM o baja
`JUICE_SHOP_MEMORY_LIMIT` a `768m`.

**El health check se queda en `starting`**
La imagen no trae shell y mantiene Node en `/nodejs/bin/node`. El archivo compose
usa esa ruta absoluta; si lo editaste a `node`, el exec falla con
`executable file not found in $PATH`. Restaura el archivo original y recrea:
`sudo docker compose up -d --force-recreate`.

**Juice Shop no es accesible desde el participante**
Revisa la dirección de publicación y el firewall:
`docker port vulnserver-juice-shop`, `sudo ufw status verbose` y `LAB_BIND_ADDR`
en `/opt/vulnserver/web/.env`.

**`docker compose` no encontrado**
El paquete de Ubuntu es `docker-compose-v2`; el binario es `docker compose`
(complemento). Los hosts más viejos necesitan `docker-compose` (v1) — instala
`docker-compose-v2` en su lugar.

## Escenarios

**El Escenario B no se activa**
```bash
id labpriv; getent group labpriv
command -v visudo
sudo visudo -cf /etc/sudoers.d/vulnserver-lab-b
```
La activación valida el archivo antes de instalarlo; si la validación falla, se
aborta sin tocar la política del host.

**sudo dice "no new privileges" o ignora la regla**
Revisa el modo del archivo (`0440`) y que el nombre no tenga punto:
`/etc/sudoers.d/vulnserver-lab-b` es válido; `...lab-b.conf` se ignora.

**El Escenario C no hace nada**
```bash
systemctl status cron
sudo cat /etc/cron.d/vulnserver-lab-c
sudo tail -50 /var/log/syslog | grep CRON
```
Cron ejecuta la tarea al inicio de cada minuto; espera hasta 60 segundos. El
script reemplazado debe ser ejecutable y legible por root.

**`verify` devuelve 1 pero el laboratorio parece activo**
`verify` revisa la *vulnerabilidad*, no el archivo de estado. Un `FAIL` significa
que la vulnerabilidad ya no está (por ejemplo después del hardening) — eso es lo
esperado tras la remediación.

## Firewall

**UFW no se deja habilitar / te deja fuera de SSH**
Permite siempre SSH desde tu red de administración **antes** de habilitar:
```bash
sudo ufw allow from 192.168.56.0/24 to any port 22 proto tcp
sudo ufw --force enable
```
Si pierdes el acceso, usa la consola del hipervisor: `sudo ufw disable`.

**Docker se salta UFW**
Docker inserta sus propias reglas de iptables; un puerto publicado puede ser
alcanzable aunque UFW lo niegue. Publica en una dirección específica
(`LAB_BIND_ADDR`) y apóyate también en el firewall del proveedor o del
hipervisor. Nunca publiques en `0.0.0.0` en un host con interfaz pública.

## auditd

**`auditctl: command not found`**
`sudo apt install -y auditd audispd-plugins`.

**Las reglas no sobreviven al reinicio**
Ubuntu carga `/etc/audit/rules.d/*.rules` mediante `augenrules`; asegúrate de que
el archivo sea `0640 root:root` y ejecuta `sudo augenrules --load`. Revisa con
`sudo auditctl -l`.

**`ausearch` no devuelve nada**
Dale una clave y una ventana: `sudo ausearch -k vulnserver_flags -ts today`. No
se registra nada hasta que se toca la ruta auditada.

## Logs

**`events.log` no se actualiza**
El directorio de logs es solo de root. Ejecuta las herramientas con `sudo`. Si el
directorio se borró, vuelve a crearlo:
`sudo ./scripts/permissions/apply_permissions.sh base`.

**Necesitas probar que los logs no fueron modificados**
```bash
sudo chattr +a /opt/vulnserver/logs/events.log
lsattr /opt/vulnserver/logs/events.log
sha256sum /opt/vulnserver/logs/events.log | tee /root/events.sha256
```
Copia los archivos fuera del host después de cada grupo.

## Pruebas

**La suite de contenedor falla en la instalación**
La suite ejecuta `install.sh --profile container`, que omite Docker, UFW, auditd
y SSH. Un fallo ahí es un bug real del script: revisa
`reports/test-run-<ts>.log` y `/tmp/install.log`, que se imprimen en el bloque de
error.

**`docker: permission denied` en el runner de pruebas**
El runner necesita acceso al daemon de Docker (root o el grupo `docker`). No
necesita `sudo` para nada más.

## Reinicio completo

```bash
sudo ./reset-lab.sh --yes          # estado, flags, datos de práctica
sudo ./uninstall.sh --yes --purge  # elimina todo (conserva adminlab)
sudo ./install.sh --install-deps --activate a,b,c
```

Si incluso eso falla, restaura la instantánea del hipervisor
`vulnserver-clean`.
