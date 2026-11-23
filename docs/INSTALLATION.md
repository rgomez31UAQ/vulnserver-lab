# Instalación

Esta guía despliega VulnServer en **Ubuntu Server 24.04 LTS**. El proyecto es un
laboratorio de servidor, no un servicio web alojado: necesita root, cuentas
reales, SSH, cron y Docker. Instálalo en una VM que puedas destruir.

## 1. Elige la plataforma

| Plataforma | Adecuada | Notas |
|---|---|---|
| QEMU/KVM + Virtual Machine Manager | sí | recomendada; las instantáneas son el rollback más rápido |
| Proxmox / VMware / Hyper-V | sí | usa una red NAT o host-only |
| Docker sobre un host Linux | limitado | `--profile container` solo para CI; sin SSH/UFW/auditd |
| VPS en la nube | sí, con cuidado | consulta [CLOUD_DEPLOYMENT.md](CLOUD_DEPLOYMENT.md) |
| Host compartido o de producción | **no** | el laboratorio entrega root por diseño |

Recursos mínimos: 2 vCPU, 2 GB de RAM, 20 GB de disco (se recomiendan 25 GB con
la imagen de Juice Shop).

## 2. Prepara una red aislada

1. Red del hipervisor: **NAT** o **host-only**, no en puente hacia una red con
   equipos de otras personas.
2. Anota la subred del laboratorio, por ejemplo `192.168.56.0/24`.
3. Conserva una segunda vía de administración (la consola del hipervisor) para que
   un error de firewall no te deje fuera.

## 3. Instala Ubuntu Server 24.04

- Arquitectura: amd64 (arm64 funciona; QEMU/KVM en Apple Silicon requiere UEFI).
- Crea la cuenta del propietario, por ejemplo `adminlab`, con tu llave pública
  SSH.
- **No** instales un entorno de escritorio; el laboratorio es un servidor.
- Habilita el servidor OpenSSH durante la instalación.
- Después del primer arranque:

```bash
sudo apt update && sudo apt upgrade -y
sudo timedatectl set-timezone UTC     # marcas de tiempo de evidencia consistentes
```

## 4. Lleva el proyecto al servidor

```bash
sudo apt install -y git
git clone <url-de-tu-fork> ~/vulnserver
cd ~/vulnserver
```

O copia el directorio con `scp -r ./vulnserver adminlab@192.168.56.10:/home/adminlab/`.

## 5. Revisa la configuración

Abre `config/lab.conf`. Los valores que más probablemente cambies:

| Variable | Valor por omisión | Significado |
|---|---|---|
| `SSH_ALLOWED_NETS` | `192.168.56.0/24 10.10.0.0/24` | quién puede llegar a SSH |
| `LAB_ALLOWED_NETS` | el mismo | quién puede llegar a Juice Shop |
| `JUICE_SHOP_PORT` | `3000` | puerto web publicado |
| `LAB_BIND_ADDR` | `0.0.0.0` | dirección de publicación (el firewall la restringe) |
| `LAB_USER_PASSWORD` | `LabUser!2026` | contraseña solo del laboratorio, compartida con el compañero |
| `ADMIN_USER_PASSWORD` | `AdminLab!2026` | cuenta del propietario (¡cámbiala!) |

Todos los valores se pueden sobrescribir por ejecución sin editar el archivo:

```bash
sudo SSH_ALLOWED_NETS="192.168.56.0/24" JUICE_SHOP_PORT=3000 ./install.sh
```

## 6. Ejecuta el instalador

```bash
sudo ./install.sh --install-deps --activate a,b,c
```

Qué hace, en orden:

1. verifica el sistema operativo, el puerto y las herramientas base necesarias;
2. instala los paquetes faltantes (`jq`, `curl`, `cron`, `sudo`, `ufw`, `auditd`,
   `docker.io`, `docker-compose-v2`) cuando se pasa `--install-deps`;
3. crea `/opt/vulnserver/{bin,flags,logs,backups,reports,state,lab,web}` y aplica
   el modelo base de permisos;
4. crea `adminlab` (sudo), `labuser` (sin privilegios) y `labpriv` (intermedia,
   contraseña bloqueada);
5. instala la política base de sudo (labuser no tiene derechos de root);
6. genera las tres flags con identificadores aleatorios;
7. instala el drop-in de sshd (login de root deshabilitado) y lo valida con
   `sshd -t` antes de recargar;
8. instala Docker si hace falta y arranca Juice Shop con `docker compose`;
9. aplica las reglas de UFW y el conjunto de reglas de auditd;
10. activa los escenarios solicitados.

Opciones útiles:

```
--install-deps     instala los paquetes faltantes automáticamente
--activate a,b,c   activa escenarios después de la instalación
--no-docker        omite Docker y Juice Shop
--no-firewall      no toca UFW (por ejemplo, detrás de un firewall externo)
--no-auditd        omite las reglas de auditd
--no-ssh           no modifica sshd
--port N           puerto de Juice Shop
--profile container perfil restringido para CI/pruebas
--skip-os-check    permite hosts que no son Ubuntu (solo VMs desechables)
-y                 sin interacción
-n                 simulación (dry run)
```

Cada ejecución agrega líneas a `/opt/vulnserver/logs/events.log`.

## 7. Verifica la instalación

```bash
sudo ./lab-manager.sh status
sudo ./audit.sh --stdout | head -40
sudo ./scripts/flags/generate_flags.sh verify
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
```

Se espera: tres cuentas, tres flags con la propiedad documentada, Juice Shop con
`HTTP 200` y el reporte de auditoría generado.

## 8. Prueba la ruta de acceso como participante

Desde otra máquina en la red permitida:

```bash
ssh labuser@192.168.56.10        # contraseña: LabUser!2026
cat /opt/vulnserver/flags/user.txt
sudo -n true; echo "salida de sudo: $?"   # debe fallar
```

Si SSH rechaza la conexión, consulta [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
Nunca compartas las credenciales de `adminlab` con el participante.

## 9. Entrega el material del participante

Dale al participante **solo** `docs/ATTACKER_GUIDE.md`. Contiene el alcance, las
flags que debe recolectar y la plantilla de reporte, y ninguna solución. Guarda
`docs/INSTRUCTOR_SOLUTIONS.md` para ti.

## 10. Instantánea

Antes del ejercicio, toma una instantánea del hipervisor (`vulnserver-clean`).
Restáurala entre grupos en lugar de reinstalar. Si no hay instantáneas
disponibles:

```bash
sudo ./reset-lab.sh --yes
```

## Desinstalación

```bash
sudo ./uninstall.sh            # detiene servicios, conserva logs/flags/backups
sudo ./uninstall.sh --purge    # además borra el directorio de estado
```

`adminlab` siempre se conserva para que nunca pierdas la cuenta de recuperación.
