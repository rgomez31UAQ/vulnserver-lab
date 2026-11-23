# Guía del administrador

Para el **propietario** de la instancia de VulnServer (la cuenta `adminlab`). El
atacante recibe [ATTACKER_GUIDE.md](ATTACKER_GUIDE.md) en su lugar.

## 1. Modelo mental

- `/opt/vulnserver` es el estado en tiempo de ejecución: flags, logs, respaldos,
  reportes, datos del laboratorio y la copia instalada de las herramientas
  (`/opt/vulnserver/bin`).
- El checkout de git es la fuente de verdad de scripts y configuración.
- Los escenarios son interruptores independientes guardados en
  `/opt/vulnserver/state/scenario-*.state`.
- `adminlab` nunca participa en el ejercicio; es tu vía de recuperación.

## 2. Interfaz de terminal

```bash
sudo /opt/vulnserver/bin/lab-manager.sh      # menú
```

| Opción | Acción |
|---|---|
| 1 | Estado: contenedor, SSH, firewall, auditd, escenarios, puertos, flags |
| 2 | Instalar dependencias / volver a ejecutar el instalador |
| 3 / 4 | Iniciar / detener servicios |
| 5 / 6 | Activar / desactivar un escenario (o todos) |
| 7 | Auditoría de solo lectura |
| 8 | Hardening |
| 9 | Reporte de actividad |
| 10 | Reiniciar el laboratorio |
| 11 | Documentación |
| 12 | Salir |

Equivalentes sin interacción: `status`, `start`, `stop`, `activate a`,
`deactivate all`, `audit`, `harden`, `report`, `reset`, `docs`, `logs`, `ports`.

## 3. Cuentas

| Cuenta | Propósito | Grupos | Contraseña |
|---|---|---|---|
| `adminlab` | propietario, administración total | `sudo` | de `config/lab.conf` (cámbiala) |
| `labuser` | punto de entrada del participante | solo su propio grupo | compartida con el participante |
| `labpriv` | nivel intermedio, Escenario B | solo su propio grupo | bloqueada; no permite iniciar sesión |

```bash
sudo ./scripts/users/create_users.sh status
sudo passwd adminlab                      # rota la contraseña del propietario
sudo ./scripts/users/create_users.sh remove   # elimina cuentas del laboratorio, conserva adminlab
```

Reglas:

- nunca agregues `labuser` a `sudo`, `adm` ni `docker`;
- nunca habilites el login de root por SSH;
- rota la contraseña de `labuser` entre grupos (`sudo passwd labuser`) y avísale
  al nuevo participante.

## 4. Control de escenarios

```bash
sudo ./scripts/scenarios/scenario-a.sh activate|deactivate|status|verify
sudo ./scripts/scenarios/scenario-b.sh activate|deactivate|status|verify
sudo ./scripts/scenarios/scenario-c.sh activate|deactivate|status|verify
```

Comportamiento de cada comando:

- `activate` crea un **punto de restauración** en
  `/opt/vulnserver/backups/restore-<id>-<ts>/` con un `restore.sh` y un
  manifiesto (quién, cuándo, host), y después aplica la configuración vulnerable.
- `deactivate` restaura la línea base segura de ese escenario.
- `verify` termina con código 0 solo si la vulnerabilidad está presente
  (verificación automatizada).
- Toda acción se registra en `events.log`.

Se admite la activación independiente: solo A, solo B, solo C o cualquier
combinación.

## 5. Flags

```bash
sudo ./scripts/flags/generate_flags.sh generate --force   # rota las tres
sudo ./scripts/flags/generate_flags.sh verify             # revisa dueño/grupo/modo
sudo ./scripts/flags/generate_flags.sh show               # imprime los valores (solo admin)
```

| Archivo | Dueño | Modo | Accesible por |
|---|---|---|---|
| `flags/user.txt` | `labuser:labuser` | `600` | labuser |
| `flags/privilege.txt` | `root:labpriv` | `640` | labpriv, root |
| `flags/root.txt` | `root:root` | `400` | root |

Secuencia esperada para calificar: flag de usuario con el acceso inicial, flag de
privilegio al llegar a `labpriv`, flag de root al ser root. Cualquier sesión de
root puede leer las tres, así que califica el *orden y la evidencia*, no solo las
cadenas.

Guarda los valores en algún lugar fuera de la VM si necesitas verificar una
entrega; `reset-lab.sh` los rota.

## 6. Servicios

```bash
sudo ./lab-manager.sh status
cd /opt/vulnserver/web && sudo docker compose ps
sudo docker compose -f /opt/vulnserver/web/docker-compose.yml logs --tail 50
sudo ./lab-manager.sh start|stop
```

SSH: `systemctl status ssh`, archivo drop-in
`/etc/ssh/sshd_config.d/99-vulnserver.conf`.

## 7. Logs y monitoreo

| Fuente | Ubicación |
|---|---|
| Eventos del laboratorio (JSONL, un objeto por línea) | `/opt/vulnserver/logs/events.log` |
| Bitácora legible del laboratorio | `/opt/vulnserver/logs/vulnserver.log` |
| Transcripción de sudo (entrada/salida) | `/var/log/sudo-vulnserver.log` |
| SSH / autenticación | `journalctl -u ssh`, `/var/log/auth.log` |
| Cron | `journalctl -u cron`, `/var/log/syslog` |
| auditd | `ausearch -k vulnserver_flags`, `aureport` |
| Docker | `docker logs vulnserver-juice-shop` |
| Conjunto de reglas instalado | `/etc/audit/rules.d/vulnserver.rules` |

El directorio de logs es `root:root 0750`, así que `labuser` no puede leerlo ni
modificarlo. `events.log` registra: marca de tiempo, host, actor (usuario real
que invoca), evento, servicio, escenario, resultado y detalle.

Genera un reporte:

```bash
sudo ./lab-manager.sh report          # o: sudo ./scripts/monitoring/report.sh --days 7
```

La salida va a `/opt/vulnserver/reports/lab-report-<ts>.md`. Los valores de las
flags nunca se escriben en los reportes.

## 8. Ciclo de auditoría y hardening

```bash
sudo ./audit.sh                       # solo lectura, escribe reports/audit-<ts>.md
sudo ./audit.sh --only sudo,cron,suid # enfoque específico
sudo ./harden.sh                      # interactivo: analiza, confirma, corrige
sudo ./harden.sh --apply --yes        # sin interacción
sudo ./harden.sh --restore /opt/vulnserver/backups/files-<ts>
```

Flujo de trabajo recomendado para el ejercicio:

1. Audita antes del ataque; conserva el reporte como evidencia del "antes".
2. Ejecuta el ataque; recoge el reporte del estudiante.
3. `harden.sh --apply` (o deja que el propietario lo haga a mano siguiendo
   [HARDENING_GUIDE.md](HARDENING_GUIDE.md)).
4. Audita de nuevo; el reporte del "después" debe mostrar los hallazgos
   resueltos.
5. `reset-lab.sh` antes del siguiente grupo.

Antes de deshabilitar la autenticación por contraseña en SSH, asegúrate de que
los `authorized_keys` estén distribuidos: `harden.sh` pide confirmación
exactamente por esta razón.

## 9. Respaldos y restauración

| Directorio | Contenido | Retención |
|---|---|---|
| `backups/files-<ts>/` | archivos reemplazados por `harden.sh` + `index.txt` | uno por grupo |
| `backups/restore-<id>-<ts>/` | punto de restauración automático por activación | uno por grupo |
| `backups/logs-<ts>.tar.gz` | logs archivados por `reset-lab.sh` | conservar como evidencia |

```bash
sudo tar -czf /root/vulnserver-backup-$(date +%F).tar.gz -C /opt vulnserver
```

Las instantáneas del hipervisor son el rollback más confiable; toma una después
de una instalación limpia y otra después del hardening.

Restaurar un respaldo de hardening:

```bash
sudo ./harden.sh --restore /opt/vulnserver/backups/files-20261123-101500
sudo ./audit.sh --stdout | head -30
```

## 10. Acceso remoto

Preferido: túnel WireGuard y, después, SSH/HTTP solo a través del túnel.

```bash
sudo apt install -y wireguard
sudo ./config/ufw/ufw-rules.sh apply
# Luego restringe SSH solo a la red del túnel:
#   SSH_ALLOWED_NETS="10.8.0.0/24" sudo ./install.sh --no-docker --no-auditd
```

Consulta [CLOUD_DEPLOYMENT.md](CLOUD_DEPLOYMENT.md) para una configuración
WireGuard completa y para las reglas del firewall en la nube.

## 11. Entre grupos

```bash
sudo ./reset-lab.sh --yes        # desactiva, limpia datos de práctica, rota flags
sudo ./audit.sh                  # confirma la línea base
```

`reset-lab.sh` nunca borra `backups/`.

## 12. Retiro del laboratorio

```bash
sudo ./uninstall.sh            # conserva el estado como evidencia
sudo ./uninstall.sh --purge    # elimina /opt/vulnserver
# finalmente borra la VM
```

## 13. Lista de verificación del operador

Antes de entregar el laboratorio:

- [ ] VM en una red aislada/NAT e instantánea tomada
- [ ] contraseña de `adminlab` rotada, llaves instaladas y no compartidas
- [ ] contraseña de `labuser` compartida solo con el participante
- [ ] escenarios activados según lo previsto (`lab-manager.sh status`)
- [ ] Juice Shop accesible solo desde la red del participante
- [ ] UFW activo, sin puertos de base de datos ni de administración escuchando
- [ ] auditd activo, `events.log` escribible solo por root
- [ ] copia del instructor de las flags guardada fuera de la VM
- [ ] el participante recibió solo `ATTACKER_GUIDE.md`
