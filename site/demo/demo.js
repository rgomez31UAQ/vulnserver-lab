/*
 * VulnServer — demo en el navegador.
 *
 * Simulación educativa del laboratorio. NO ejecuta un kernel: reproduce el
 * sistema de archivos, los permisos, las cuentas y los tres escenarios para
 * practicar el flujo. UFW, auditd, Docker, sshd y systemd no existen aquí.
 *
 * El motor no depende del DOM, así que puede probarse con Node:
 *   const { makeLab } = require('./demo.js');
 */
(function (global) {
  'use strict';

  var FLAG_RE_ALL = /VS\{[A-Z0-9-]+\}/g;
  var HOME = '/home/labuser';

  var USERS = {
    adminlab: { uid: 1000, group: 'adminlab', groups: ['adminlab', 'sudo'], home: '/home/adminlab' },
    labuser: { uid: 1001, group: 'labuser', groups: ['labuser'], home: '/home/labuser' },
    labpriv: { uid: 1002, group: 'labpriv', groups: ['labpriv'], home: '/nonexistent' },
    root: { uid: 0, group: 'root', groups: ['root'], home: '/root' }
  };

  function rid(n) {
    var s = '';
    var chars = 'ABCDEF0123456789';
    for (var i = 0; i < n; i++) s += chars[Math.floor(Math.random() * chars.length)];
    return s;
  }

  function newFlags() {
    return {
      user: 'VS{USER-' + rid(12) + '}',
      privilege: 'VS{PRIV-' + rid(12) + '}',
      root: 'VS{ROOT-' + rid(12) + '}'
    };
  }

  /* ---------------- utilidades de texto ---------------- */

  function tokenize(s) {
    var out = [], cur = '', q = null, esc = false;
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (esc) { cur += ch; esc = false; continue; }
      // dentro de comillas simples todo es literal, incluido la barra invertida
      if (q === "'") { if (ch === "'") q = null; else cur += ch; continue; }
      // dentro de comillas dobles la barra se conserva (printf necesita \n)
      if (ch === '\\') { if (q === '"') cur += ch; else esc = true; continue; }
      if (q) { if (ch === q) q = null; else cur += ch; continue; }
      if (ch === '"' || ch === "'") { q = ch; continue; }
      if (/\s/.test(ch)) { if (cur) { out.push(cur); cur = ''; } continue; }
      cur += ch;
    }
    if (cur) out.push(cur);
    return out;
  }

  function normalize(p) {
    var abs = p.charAt(0) === '/';
    var parts = p.split('/'), stack = [];
    for (var i = 0; i < parts.length; i++) {
      var seg = parts[i];
      if (!seg || seg === '.') continue;
      if (seg === '..') { if (stack.length) stack.pop(); continue; }
      stack.push(seg);
    }
    return '/' + stack.join('/');
  }

  function dirname(p) {
    var n = normalize(p);
    if (n === '/') return '/';
    var idx = n.lastIndexOf('/');
    return idx <= 0 ? '/' : n.slice(0, idx);
  }

  function unescape(text) {
    return text.replace(/\\n/g, '\n').replace(/\\t/g, '\t').replace(/\\\\/g, '\\');
  }

  /* ---------------- motor ---------------- */

  function makeLab() {
    var fs = new Map();
    var state = {
      user: 'labuser',
      cwd: HOME,
      scenarios: { a: true, b: true, c: true },
      flags: newFlags(),
      captured: [],
      hardened: false,
      shell: null,
      cronRuns: 0
    };

    function put(path, node) { fs.set(normalize(path), node); }
    function mkdir(path, owner, group, mode) {
      put(path, { type: 'dir', owner: owner || 'root', group: group || 'root', mode: mode || 0o755 });
    }
    function mkfile(path, content, owner, group, mode) {
      put(path, {
        type: 'file', content: content,
        owner: owner || 'root', group: group || 'root', mode: mode === undefined ? 0o644 : mode
      });
    }
    function node(path) { return fs.get(normalize(path)); }

    function build() {
      fs.clear();
      mkdir('/');
      mkdir('/home');
      mkdir('/home/labuser', 'labuser', 'labuser', 0o750);
      mkdir('/home/adminlab', 'adminlab', 'adminlab', 0o750);
      mkdir('/root', 'root', 'root', 0o700);
      mkdir('/etc');
      mkdir('/etc/sudoers.d', 'root', 'root', 0o750);
      mkdir('/etc/cron.d');
      mkdir('/etc/ssh');
      mkdir('/etc/ssh/sshd_config.d');
      mkdir('/opt');
      mkdir('/opt/vulnserver');
      mkdir('/opt/vulnserver/flags');
      mkdir('/opt/vulnserver/logs', 'root', 'root', 0o750);
      mkdir('/opt/vulnserver/lab');
      mkdir('/opt/vulnserver/lab/perms', 'root', 'root', state.scenarios.a ? 0o777 : 0o755);
      mkdir('/opt/vulnserver/lab/cron', 'root', 'root', state.scenarios.c ? 0o777 : 0o755);
      mkdir('/opt/vulnserver/reports');
      mkdir('/opt/vulnserver/backups', 'root', 'root', 0o700);
      mkdir('/tmp', 'root', 'root', 0o1777);
      mkdir('/usr');
      mkdir('/usr/bin');
      mkdir('/usr/local');
      mkdir('/usr/local/bin');
      mkdir('/var');
      mkdir('/var/log');

      mkfile('/etc/passwd',
        'root:x:0:0:root:/root:/bin/bash\n' +
        'adminlab:x:1000:1000:Propietario:/home/adminlab:/bin/bash\n' +
        'labuser:x:1001:1001:Participante:/home/labuser:/bin/bash\n' +
        'labpriv:x:1002:1002:Nivel intermedio:/nonexistent:/usr/sbin/nologin\n');
      mkfile('/etc/shadow', 'root:*:19000:0:99999:7:::\nadminlab:$6$...:19000:0:99999:7:::\nlabuser:$6$...:19000:0:99999:7:::\nlabpriv:! locked\n', 'root', 'shadow', 0o640);
      mkfile('/etc/ssh/sshd_config.d/99-vulnserver.conf',
        'PermitRootLogin no\nAllowUsers adminlab labuser\nMaxAuthTries 3\n');
      mkfile('/etc/sudoers.d/vulnserver-lab-b',
        'labuser  ALL=(labpriv) NOPASSWD: /usr/bin/tar, /usr/bin/cat\n' +
        'labpriv ALL=(root)   NOPASSWD: /usr/local/bin/lab-healthcheck\n',
        'root', 'root', 0o440);
      if (!state.scenarios.b) fs.delete('/etc/sudoers.d/vulnserver-lab-b');

      mkfile('/etc/cron.d/vulnserver-lab-c',
        '# root ejecuta el script cada minuto\n' +
        '* * * * * root /opt/vulnserver/lab/cron/lab-cleanup.sh\n');
      if (!state.scenarios.c) fs.delete('/etc/cron.d/vulnserver-lab-c');

      mkfile('/opt/vulnserver/flags/user.txt', state.flags.user, 'labuser', 'labuser', 0o600);
      mkfile('/opt/vulnserver/flags/privilege.txt', state.flags.privilege, 'root', 'labpriv', 0o640);
      mkfile('/opt/vulnserver/flags/root.txt', state.flags.root, 'root', 'root', 0o400);
      mkfile('/opt/vulnserver/logs/events.log', state.events ? state.events.join('\n') + (state.events.length ? '\n' : '') : '');
      mkfile('/opt/vulnserver/lab/perms/NOTAS.txt',
        'Rutina de respaldo: copia los datos de practica antes de limpiar.\n');
      mkfile('/opt/vulnserver/lab/cron/lab-cleanup.sh',
        '#!/bin/bash\n# Limpieza de restos de practicas (se ejecuta como root)\n' +
        'find /tmp -maxdepth 1 -name "lab-*" -mtime +1 -delete\n');
      mkfile('/usr/bin/find',
        '#!/bin/sh\n# (binario simulado)\n',
        'root', 'root', state.scenarios.a ? 0o4755 : 0o755);
      mkfile('/usr/local/bin/lab-healthcheck',
        '#!/bin/bash\necho "lab ok"\n',
        'root', state.scenarios.b ? 'labpriv' : 'root',
        state.scenarios.b ? 0o774 : 0o755);
      mkfile('/var/log/lab-cleanup.log', '', 'root', 'root', 0o640);
    }

    /* ---------------- permisos ---------------- */

    function hasPerm(user, n, bit) {
      if (!n) return false;
      if (user === 'root') return true;
      var u = USERS[user];
      if (!u) return false;
      var shift = n.owner === user ? 6 : (u.groups.indexOf(n.group) >= 0 ? 3 : 0);
      return ((n.mode >> shift) & bit) !== 0;
    }

    function traverse(user, path) {
      var parts = normalize(path).split('/').filter(Boolean), cur = '';
      for (var i = 0; i < parts.length - 1; i++) {
        cur += '/' + parts[i];
        var n = fs.get(cur);
        if (!n || n.type !== 'dir' || !hasPerm(user, n, 1)) return false;
      }
      return true;
    }

    function readable(user, path) {
      var n = node(path);
      return !!n && n.type === 'file' && traverse(user, path) && hasPerm(user, n, 4);
    }

    function searchable(user, path) {
      var n = node(path);
      return !!n && n.type === 'dir' && traverse(user, path) && hasPerm(user, n, 1);
    }

    function modeStr(m) {
      function bits(shift) {
        return ((m >> shift) & 4 ? 'r' : '-') + ((m >> shift) & 2 ? 'w' : '-');
      }
      var owner = bits(6) + ((m >> 6) & 1 ? ((m & 0o4000) ? 's' : 'x') : ((m & 0o4000) ? 'S' : '-'));
      return (m & 0o4000 ? '' : '') + owner + bits(3) + ((m >> 3) & 1 ? 'x' : '-') + bits(0) + ((m >> 0) & 1 ? 'x' : '-');
    }

    function fmtDate() { return '23 nov 12:00'; }

    function resolve(p, cwd) {
      if (!p) return cwd;
      if (p === '~') return USERS[state.user].home;
      if (p.indexOf('~/') === 0) return normalize(USERS[state.user].home + p.slice(1));
      return p.charAt(0) === '/' ? normalize(p) : normalize(cwd + '/' + p);
    }

    function children(path) {
      var p = normalize(path), prefix = p === '/' ? '/' : p + '/', seen = [];
      fs.forEach(function (n, key) {
        if (!key.startsWith(prefix) || key === p) return;
        var rest = key.slice(prefix.length);
        if (rest.indexOf('/') === -1) seen.push(rest);
      });
      return seen.sort();
    }

    /* ---------------- eventos ---------------- */

    function logEvent(actor, event, detail) {
      var line = JSON.stringify({
        ts: new Date().toISOString(), host: 'vulnserver',
        actor: actor, event: event, detail: detail || ''
      });
      if (!state.events) state.events = [];
      state.events.push(line);
      var log = node('/opt/vulnserver/logs/events.log');
      if (log) log.content += line + '\n';
    }
    state.events = [];

    /* ---------------- ejecución ---------------- */

    function runAs(line, user, cwd) {
      var out = [];
      function push(text, cls) { out.push({ text: text === undefined ? '' : String(text), cls: cls || 'out' }); }
      var raw = line.trim();
      if (!raw) return out;

      // redirección simple: cmd > destino / cmd >> destino
      var split = splitRedirect(raw);
      var cmdline = raw;
      if (split) cmdline = split.cmd;

      var argv = tokenize(cmdline);
      if (!argv.length) return out;
      var cmd = argv[0];
      var args = argv.slice(1);

      function writeTarget(text) {
        var target = resolve(split.target, cwd);
        var existing = node(target);
        if (!traverse(user, target)) {
          push(cmd + ': ' + split.target + ': permiso denegado', 'err');
          return;
        }
        if (existing) {
          if (existing.type !== 'file' || !hasPerm(user, existing, 2)) {
            push(cmd + ': ' + split.target + ': permiso denegado', 'err');
            return;
          }
          existing.content = split.op === '>>' ? existing.content + text : text;
        } else {
          var pn = node(dirname(target));
          if (!pn || pn.type !== 'dir' || !hasPerm(user, pn, 2) || !hasPerm(user, pn, 1)) {
            push(cmd + ': no se puede escribir en ' + split.target + ': permiso denegado', 'err');
            return;
          }
          mkfile(target, text, user, USERS[user].group, 0o644);
        }
      }

      if (!split) {
        execute(cmd, args, user, cwd, push, writeTarget);
        return out;
      }
      var buffer = [];
      execute(cmd, args, user, cwd, function (t, c) { buffer.push({ text: t, cls: c || 'out' }); }, writeTarget);
      if (buffer.some(function (l) { return l.cls === 'err'; })) {
        buffer.forEach(function (l) { push(l.text, l.cls); });
        return out;
      }
      writeTarget(redirectText(cmd, args, buffer));
      return out;
    }

    function redirectText(cmd, args, produced) {
      if (cmd === 'echo' || cmd === 'printf') {
        var body = args.join(' ');
        return cmd === 'printf' ? unescape(body) : body + '\n';
      }
      var text = produced.map(function (l) { return l.text; }).join('\n');
      return text ? text + '\n' : '';
    }

    function splitRedirect(line) {
      var q = null, esc = false, idx = -1;
      for (var i = 0; i < line.length; i++) {
        var ch = line.charAt(i);
        if (esc) { esc = false; continue; }
        if (ch === '\\') { esc = true; continue; }
        if (q) { if (ch === q) q = null; continue; }
        if (ch === '"' || ch === "'") { q = ch; continue; }
        if (ch === '>') idx = i;
      }
      if (idx < 0) return null;
      var op = line.charAt(idx + 1) === '>' ? '>>' : '>';
      var target = line.slice(idx + (op === '>>' ? 2 : 1)).trim();
      if (!target) return null;
      return { cmd: line.slice(0, idx).trim(), op: op, target: target.split(/\s+/)[0] };
    }

    function execute(cmd, args, user, cwd, push, writeTarget) {
      if (cmd.indexOf('/') >= 0) {
        return execute(cmd.split('/').pop(), args, user, cwd, push, writeTarget);
      }
      switch (cmd) {
        case 'help': return cmdHelp(push);
        case 'whoami': push(user); return;
        case 'id': {
          var u = USERS[user];
          push('uid=' + u.uid + '(' + user + ') gid=' + u.uid + '(' + u.group + ') groups=' +
            u.groups.map(function (g) { return g; }).join(','));
          return;
        }
        case 'pwd': push(cwd); return;
        case 'cd': return cmdCd(args, user, cwd, push);
        case 'ls': return cmdLs(args, user, cwd, push);
        case 'cat': return cmdCat(args, user, cwd, push);
        case 'tail': return cmdTail(args, user, cwd, push);
        case 'echo':
        case 'printf': push(cmd === 'printf' ? unescape(args.join(' ')) : args.join(' ')); return;
        case 'mv': return cmdMv(args, user, cwd, push);
        case 'chmod': return cmdChmod(args, user, cwd, push);
        case 'find': return cmdFind(args, user, cwd, push);
        case 'sudo': return cmdSudo(args, user, cwd, push);
        case 'ss': return cmdSs(args, push);
        case 'ufw': return cmdUfw(args, push);
        case 'audit.sh':
        case './audit.sh': return cmdAudit(args, user, push);
        case 'harden.sh':
        case './harden.sh': return cmdHarden(args, user, push);
        case 'reset-lab.sh':
        case './reset-lab.sh': return cmdReset(args, user, push);
        case 'lab-manager.sh':
        case './lab-manager.sh': return cmdLabManager(args, user, push);
        case 'generate_flags.sh':
        case './generate_flags.sh': return cmdFlags(args, user, push);
        default:
          push(cmd + ': orden no encontrada', 'err');
      }
    }

    function cmdCd(args, user, cwd, push) {
      var target = resolve(args[0] || USERS[user].home, cwd);
      var n = node(target);
      if (!n) { push('cd: ' + (args[0] || target) + ': no existe', 'err'); return; }
      if (n.type !== 'dir') { push('cd: ' + args[0] + ': no es un directorio', 'err'); return; }
      if (!searchable(user, target)) { push('cd: ' + args[0] + ': permiso denegado', 'err'); return; }
      state.cwd = target;
    }

    function cmdLs(args, user, cwd, push) {
      var long = false, all = false, target = null;
      args.forEach(function (a) {
        if (a === '-l' || a === '-la' || a === '-al') { long = true; if (a.indexOf('a') >= 0) all = true; }
        else if (a === '-a') all = true;
        else if (a.charAt(0) !== '-') target = a;
      });
      var path = resolve(target || '.', cwd);
      var n = node(path);
      if (!n) { push('ls: ' + (target || path) + ': no existe', 'err'); return; }
      if (n.type === 'file') {
        if (!readable(user, path)) { push('ls: ' + (target || path) + ': permiso denegado', 'err'); return; }
        emit(path);
        return;
      }
      if (!traverse(user, path) || !hasPerm(user, n, 4) || !hasPerm(user, n, 1)) {
        push('ls: ' + (target || path) + ': permiso denegado', 'err'); return;
      }
      var list = children(path).filter(function (name) { return all || name.charAt(0) !== '.'; });
      if (!list.length) return;
      if (!long) { push(list.join('  ')); return; }
      push('total ' + list.length);
      list.forEach(function (name) { emit(path === '/' ? '/' + name : path + '/' + name); });

      function emit(p) {
        var c = node(p), name = p.split('/').pop();
        push((c.type === 'dir' ? 'd' : '-') + modeStr(c.mode) + ' 1 ' + c.owner + ' ' + c.group + ' ' +
          String(c.type === 'dir' ? 4096 : (c.content || '').length).padStart(6) + ' ' +
          fmtDate() + ' ' + name);
      }
    }

    function cmdCat(args, user, cwd, push) {
      var files = args.filter(function (a) { return a.charAt(0) !== '-'; });
      if (!files.length) { push('cat: falta un archivo', 'err'); return; }
      files.forEach(function (f) {
        var p = resolve(f, cwd);
        if (!node(p)) { push('cat: ' + f + ': no existe', 'err'); return; }
        if (!readable(user, p)) { push('cat: ' + f + ': permiso denegado', 'err'); return; }
        push(node(p).content.replace(/\n$/, ''));
      });
    }

    function cmdTail(args, user, cwd, push) {
      var count = 10, file = null;
      for (var i = 0; i < args.length; i++) {
        if (args[i] === '-n') { count = parseInt(args[i + 1], 10) || 10; i++; }
        else if (args[i].charAt(0) !== '-') file = args[i];
      }
      if (!file) { push('tail: falta un archivo', 'err'); return; }
      var p = resolve(file, cwd);
      if (!node(p)) { push('tail: ' + file + ': no existe', 'err'); return; }
      if (!readable(user, p)) { push('tail: ' + file + ': permiso denegado', 'err'); return; }
      var lines = node(p).content.replace(/\n$/, '').split('\n');
      push(lines.slice(-count).join('\n'));
    }

    function cmdMv(args, user, cwd, push) {
      if (args.length < 2) { push('mv: faltan operandos', 'err'); return; }
      var src = resolve(args[0], cwd), dst = resolve(args[1], cwd);
      var sn = node(src);
      if (!sn) { push('mv: ' + args[0] + ': no existe', 'err'); return; }
      var sp = dirname(src), dp = dirname(dst);
      if (!hasPerm(user, node(sp), 2) || !hasPerm(user, node(dp), 2)) {
        push('mv: no se puede mover: permiso denegado', 'err'); return;
      }
      var target = node(dst);
      if (target && target.type === 'dir') dst = dst + '/' + src.split('/').pop();
      fs.set(normalize(dst), sn);
      fs.delete(normalize(src));
    }

    function cmdChmod(args, user, cwd, push) {
      if (args.length < 2) { push('chmod: faltan operandos', 'err'); return; }
      var mode = args[0], target = resolve(args[1], cwd), n = node(target);
      if (!n) { push('chmod: ' + args[1] + ': no existe', 'err'); return; }
      if (n.owner !== user && user !== 'root') { push('chmod: ' + args[1] + ': operación no permitida', 'err'); return; }
      if (/^u\+s$/.test(mode)) n.mode = n.mode | 0o4000;
      else if (/^u-s$/.test(mode)) n.mode = n.mode & ~0o4000;
      else if (/^[0-7]{3,4}$/.test(mode)) n.mode = parseInt(mode, 8);
      else { push('chmod: modo no válido: ' + mode, 'err'); return; }
      logEvent(user, 'CHMOD', target + ' -> ' + mode);
    }

    function cmdFind(args, user, cwd, push) {
      var start = null, execIdx = -1;
      for (var i = 0; i < args.length; i++) {
        if (args[i] === '-exec') { execIdx = i; break; }
        if (args[i].charAt(0) !== '-' && !start) start = args[i];
      }
      var base = resolve(start || '.', cwd);
      var suid = (node('/usr/bin/find').mode & 0o4000) !== 0;

      if (execIdx >= 0) {
        var parts = args.slice(execIdx + 1);
        var cmdStr = null;
        for (var j = 0; j < parts.length; j++) {
          if (parts[j] === '-c' && parts[j + 1]) { cmdStr = parts[j + 1]; break; }
        }
        if (!cmdStr) { push('find: -exec sin -c no está soportado en la demo', 'err'); return; }
        var asUser = suid ? 'root' : user;
        if (suid) push('(find conserva euid 0 por el bit SUID)', 'dim');
        var inner = runAs(cmdStr, asUser, cwd);
        inner.forEach(function (l) { push(l.text, l.cls); });
        return;
      }
      if (!node(base)) { push('find: ' + (start || base) + ': no existe', 'err'); return; }
      push(base);
    }

    function cmdSudo(args, user, cwd, push) {
      var i = 0, asUser = 'root', list = false, noPass = false;
      while (i < args.length) {
        if (args[i] === '-l') { list = true; i++; continue; }
        if (args[i] === '-n') { noPass = true; i++; continue; }
        if (args[i] === '-u' && args[i + 1]) { asUser = args[i + 1]; i += 2; continue; }
        break;
      }
      var rest = args.slice(i);

      if (list) {
        if (user === 'root') { push('root puede ejecutar cualquier comando', 'out'); return; }
        if (user === 'adminlab') {
          push('Coincidencias predeterminadas para adminlab en vulnserver:');
          push('    ALL=(ALL:ALL) ALL', 'out');
          return;
        }
        if (user === 'labuser' && state.scenarios.b) {
          push('Coincidencias predeterminadas para labuser en vulnserver:');
          push('    (labpriv) NOPASSWD: /usr/bin/tar, /usr/bin/cat', 'warn');
          return;
        }
        push('Lo sentimos, el usuario ' + user + ' no puede ejecutar sudo en vulnserver.', 'err');
        return;
      }

      if (!rest.length) { push('uso: sudo [opciones] comando', 'err'); return; }

      if (user === 'root' || user === 'adminlab') {
        var innerRoot = runAs(rest.join(' '), 'root', cwd);
        innerRoot.forEach(function (l) { push(l.text, l.cls); });
        return;
      }

      if (user === 'labuser' && asUser === 'labpriv') {
        if (!state.scenarios.b) {
          push('labuser no está en el archivo sudoers.', 'err'); return;
        }
        var allowed = ['tar', 'cat'];
        var bin = rest[0].split('/').pop();
        if (allowed.indexOf(bin) < 0) {
          push('Lo sentimos, el usuario labuser no puede ejecutar ' + rest[0] + ' como labpriv.', 'err');
          return;
        }
        logEvent(user, 'SUDO', 'labuser -> labpriv: ' + rest.join(' '));
        if (bin === 'tar' && rest.join(' ').indexOf('checkpoint-action=exec=') >= 0) {
          push('[shell interactiva como labpriv — escribe «exit» para volver]', 'warn');
          state.shell = { user: user, cwd: cwd };
          state.user = 'labpriv';
          state.cwd = '/tmp';
          return;
        }
        var inner = runAs(rest.join(' '), 'labpriv', cwd);
        inner.forEach(function (l) { push(l.text, l.cls); });
        return;
      }

      if (user === 'labpriv') {
        var command = rest[0] || '';
        if (state.scenarios.b && command.indexOf('lab-healthcheck') >= 0) {
          var helper = node('/usr/local/bin/lab-healthcheck');
          logEvent(user, 'SUDO', 'labpriv -> root: lab-healthcheck');
          var script = runScript(helper.content, 'root');
          script.forEach(function (l) { push(l.text, l.cls); });
          return;
        }
        push('Lo sentimos, el usuario labpriv no puede ejecutar ' + command + ' como root.', 'err');
        return;
      }

      push('Lo sentimos, el usuario ' + user + ' no puede ejecutar sudo en vulnserver.', 'err');
    }

    function runScript(content, user) {
      var out = [];
      var lines = String(content).split('\n');
      for (var i = 0; i < lines.length; i++) {
        var l = lines[i].trim();
        if (!l || l.charAt(0) === '#') continue;
        var r = runAs(l, user, '/');
        r.forEach(function (x) { out.push(x); });
      }
      return out;
    }

    function cmdSs(args, push) {
      if (args.indexOf('-ltnp') >= 0 || args.indexOf('-tlnp') >= 0 || !args.length) {
        push('State  Recv-Q Send-Q Local Address:Port  Process');
        push('LISTEN 0      128    0.0.0.0:22          users:(("sshd",pid=721,fd=3))');
        push('LISTEN 0      128    0.0.0.0:3000        users:(("docker-proxy",pid=1337,fd=4))');
        return;
      }
      push('ss: en la demo solo se soporta «ss -ltnp»', 'dim');
    }

    function cmdUfw(args, push) {
      if (args[0] === 'status') {
        push('Status: active');
        push('To                         Action      From');
        push('--                         ------      ----');
        push('22/tcp                     ALLOW       192.168.56.0/24');
        push('3000/tcp                   ALLOW       192.168.56.0/24');
        return;
      }
      push('ufw: en la demo solo se soporta «ufw status»', 'dim');
    }

    function cmdAudit(args, user, push) {
      push('VulnServer — auditoría (simulada)', 'banner');
      push('Secciones: ssh, accounts, permissions, sudo, suid, cron, firewall');
      var fail = 0;
      if (!state.scenarios.b && !state.scenarios.c && !state.scenarios.a) {
        push('[ OK ] Ningún hallazgo abierto: los escenarios están desactivados.', 'ok');
        push('Resultado: 0 FAIL', 'ok');
        return;
      }
      if (state.scenarios.a) {
        push('[FAIL] suid: bit SUID presente en /usr/bin/find (modo ' + modeStr(node('/usr/bin/find').mode) + ')', 'err');
        fail++;
        push('[FAIL] permissions: /opt/vulnserver/lab/perms es 0777', 'err');
        fail++;
      }
      if (state.scenarios.b) {
        push('[FAIL] sudo: /etc/sudoers.d/vulnserver-lab-b delega comandos con NOPASSWD', 'err');
        fail++;
        push('[FAIL] sudo: /usr/local/bin/lab-healthcheck escribible por el grupo labpriv', 'err');
        fail++;
      }
      if (state.scenarios.c) {
        push('[FAIL] cron: tarea de root ejecuta un script en un directorio 0777', 'err');
        fail++;
      }
      push('Resultado: ' + fail + ' FAIL', fail ? 'err' : 'ok');
      logEvent(user, 'AUDIT', fail + ' hallazgos');
    }

    function cmdHarden(args, user, push) {
      if (user !== 'root') {
        push('harden.sh: se necesita root (en el laboratorio real: sudo ./harden.sh --apply)', 'err');
        return;
      }
      if (args.indexOf('--apply') < 0) {
        push('harden.sh: modo simulación. Usa «sudo ./harden.sh --apply».', 'warn');
        return;
      }
      push('== Respaldo en /opt/vulnserver/backups/files-20261123-1200 ==', 'dim');
      state.scenarios = { a: false, b: false, c: false };
      state.hardened = true;
      buildPreservingFiles();
      push('[ OK ] SUID retirado de /usr/bin/find (0755)', 'ok');
      push('[ OK ] /opt/vulnserver/lab/perms y lab/cron en 0755', 'ok');
      push('[ OK ] /etc/sudoers.d/vulnserver-lab-b eliminado', 'ok');
      push('[ OK ] /usr/local/bin/lab-healthcheck en root:root 0755', 'ok');
      push('[ OK ] /etc/cron.d/vulnserver-lab-c eliminado', 'ok');
      push('[ OK ] Registro de la acción en events.log', 'dim');
      logEvent(user, 'HARDEN', 'aplicado');
    }

    function buildPreservingFiles() {
      // conserva los archivos creados por el jugador en /tmp
      var tmp = [];
      fs.forEach(function (n, k) { if (k.indexOf('/tmp/') === 0 && n.type === 'file') tmp.push([k, n]); });
      build();
      tmp.forEach(function (pair) { fs.set(pair[0], pair[1]); });
    }

    function cmdReset(args, user, push) {
      if (args.indexOf('--yes') < 0) {
        push('reset-lab.sh: confirma con «./reset-lab.sh --yes»', 'warn');
        return;
      }
      state.flags = newFlags();
      state.captured = [];
      state.scenarios = { a: true, b: true, c: true };
      state.hardened = false;
      state.events = [];
      build();
      state.user = 'labuser';
      state.cwd = HOME;
      state.shell = null;
      push('[ OK ] Escenarios desactivados y reactivados a la línea base', 'ok');
      push('[ OK ] Flags rotadas (las anteriores ya no sirven)', 'ok');
      push('[ OK ] Datos de práctica en /tmp eliminados', 'ok');
      logEvent(user, 'RESET', 'flags rotadas');
    }

    function cmdLabManager(args, user, push) {
      if (args[0] !== 'status') {
        push('lab-manager.sh: en la demo solo se soporta «status»', 'dim');
        return;
      }
      push('VulnServer — estado', 'banner');
      push('Cuentas          adminlab (sudo), labuser, labpriv (bloqueada)');
      push('Flags            ' + state.captured.length + '/3 capturadas');
      push('Escenario A      ' + (state.scenarios.a ? 'activo (SUID en find)' : 'inactivo'));
      push('Escenario B      ' + (state.scenarios.b ? 'activo (sudoers delegado)' : 'inactivo'));
      push('Escenario C      ' + (state.scenarios.c ? 'activo (cron de root)' : 'inactivo'));
      push('Hardening        ' + (state.hardened ? 'aplicado' : 'no aplicado'));
      push('Puertos          22/tcp (SSH), 3000/tcp (Juice Shop)');
    }

    function cmdFlags(args, user, push) {
      if (args[0] !== 'verify') {
        push('generate_flags.sh: en la demo solo se soporta «verify»', 'dim');
        return;
      }
      push('user.txt        labuser:labuser 0600  ' + (node('/opt/vulnserver/flags/user.txt').mode === 0o600 ? 'OK' : 'FAIL'));
      push('privilege.txt   root:labpriv   0640  ' + (node('/opt/vulnserver/flags/privilege.txt').mode === 0o640 ? 'OK' : 'FAIL'));
      push('root.txt        root:root      0400  ' + (node('/opt/vulnserver/flags/root.txt').mode === 0o400 ? 'OK' : 'FAIL'));
    }

    function cmdHelp(push) {
      push('Comandos de la demo', 'banner');
      push('  ayuda de archivos   ls [-l] [ruta]   cat <archivo>   cd <ruta>   pwd   tail [-n N] <archivo>');
      push('  identidad           whoami   id   sudo -l');
      push('  escritura           echo <texto> > <archivo>   mv <origen> <destino>   chmod <modo> <archivo>');
      push('  escenarios          find ... -exec /bin/sh -p -c \'<cmd>\' \\;');
      push('                      sudo -u labpriv <comando>   sudo -n /usr/local/bin/lab-healthcheck');
      push('  administración      sudo ./audit.sh   sudo ./harden.sh --apply   ./reset-lab.sh --yes');
      push('                      ./lab-manager.sh status   ./generate_flags.sh verify');
      push('  entornos            ss -ltnp   ufw status');
      push('  otros               help   clear   exit (solo dentro de una shell)');
      push('Los comandos de administración piden root: cambia a adminlab y usa sudo.', 'dim');
      push('Cron está acelerado: se ejecuta cada 8 s (en la VM real, cada 60 s).', 'dim');
    }

    /* ---------------- captura de flags ---------------- */

    function captureFrom(items) {
      items.forEach(function (item) {
        var found = String(item.text).match(FLAG_RE_ALL);
        if (!found) return;
        found.forEach(function (value) {
          Object.keys(state.flags).forEach(function (key) {
            if (state.flags[key] === value && state.captured.indexOf(key) < 0) {
              state.captured.push(key);
              logEvent(state.user, 'FLAG_CAPTURED', key);
            }
          });
        });
      });
    }

    function exec(raw) {
      var out;
      var line = raw.trim();
      if (line === 'clear') return { out: [], clear: true };
      if (line === 'exit' && state.shell) {
        out = [{ text: 'Se cierra la shell de labpriv', cls: 'dim' }];
        state.user = state.shell.user;
        state.cwd = state.shell.cwd;
        state.shell = null;
        return { out: out };
      }
      out = runAs(line, state.user, state.cwd);
      captureFrom(out);
      return { out: out };
    }

    function cronTick() {
      if (!state.scenarios.c) return [];
      var script = node('/opt/vulnserver/lab/cron/lab-cleanup.sh');
      if (!script) return [];
      var out = runScript(script.content, 'root');
      state.cronRuns++;
      var log = node('/var/log/lab-cleanup.log');
      if (log) {
        log.content += '[' + new Date().toISOString() + '] cron ejecutó lab-cleanup.sh como root\n';
        if (out.length) log.content += out.map(function (l) { return l.text; }).join('\n') + '\n';
      }
      captureFrom(out);
      return out;
    }

    build();

    return {
      state: state,
      exec: exec,
      cronTick: cronTick,
      reset: function () { cmdReset(['--yes'], 'root', function () {}); },
      node: node,
      readable: readable,
      prompt: function () {
        var home = USERS[state.user].home;
        var cwd = state.cwd === home ? '~' : (state.cwd.indexOf(home + '/') === 0 ? '~' + state.cwd.slice(home.length) : state.cwd);
        return state.user + '@vulnserver:' + cwd + (state.user === 'root' ? '#' : '$');
      },
      setUser: function (u) {
        if (!USERS[u]) return;
        state.user = u;
        state.cwd = USERS[u].home;
        state.shell = null;
      }
    };
  }

  /* ---------------- interfaz ---------------- */

  function initUI() {
    var lab = makeLab();
    var screen = document.getElementById('screen');
    var form = document.getElementById('form');
    var input = document.getElementById('cmd');
    var promptEl = document.getElementById('prompt');
    var titleEl = document.getElementById('term-title');
    var history = [], hpos = 0, cronTimer = null;

    function line(text, cls) {
      var el = document.createElement('div');
      el.className = 'ln ' + (cls || 'out');
      el.textContent = text === '' ? '\u00a0' : text;
      screen.appendChild(el);
    }

    function refreshPrompt() {
      promptEl.textContent = lab.prompt();
      promptEl.className = 'prompt' + (lab.state.user === 'root' ? ' root' : '');
      titleEl.textContent = lab.state.user + '@vulnserver';
    }

    function refreshPanel() {
      document.getElementById('p-user').textContent = lab.state.user;
      var found = lab.state.captured;
      ['user', 'privilege', 'root'].forEach(function (key) {
        var li = document.querySelector('#flag-list li[data-flag="' + key + '"]');
        if (!li) return;
        var done = found.indexOf(key) >= 0;
        li.classList.toggle('done', done);
        li.querySelector('.lock').textContent = done ? '🔓' : '🔒';
        var code = li.querySelector('code');
        if (done && !li.dataset.value) {
          li.dataset.value = lab.state.flags[key];
          code.textContent = lab.state.flags[key];
        } else if (!done) {
          delete li.dataset.value;
          code.textContent = '/opt/vulnserver/flags/' + key + '.txt';
        }
      });
      document.getElementById('progress').textContent = found.length + ' de 3 flags';
      ['a', 'b', 'c'].forEach(function (s) {
        var li = document.querySelector('#scenario-list li[data-scenario="' + s + '"]');
        if (!li) return;
        li.classList.toggle('on', !!lab.state.scenarios[s]);
        li.classList.toggle('off', !lab.state.scenarios[s]);
      });
      document.getElementById('harden-state').textContent = lab.state.hardened ? 'endurecido' : 'sin endurecer';
      document.querySelectorAll('[data-user]').forEach(function (b) {
        b.setAttribute('aria-pressed', b.dataset.user === lab.state.user ? 'true' : 'false');
      });
    }

    function print(res) {
      if (res.clear) { screen.textContent = ''; return; }
      res.out.forEach(function (l) { line(l.text, l.cls); });
      screen.scrollTop = screen.scrollHeight;
      refreshPanel();
    }

    function echo(raw) {
      line(lab.prompt() + ' ' + raw, 'cmd-echo');
    }

    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var raw = input.value;
      input.value = '';
      if (!raw.trim()) { refreshPrompt(); return; }
      history.push(raw);
      hpos = history.length;
      echo(raw);
      var before = lab.state.user;
      var res = lab.exec(raw);
      print(res);
      if (lab.state.user === 'root' && before !== 'root') {
        line('(ahora eres root: prueba cat /opt/vulnserver/flags/root.txt)', 'dim');
      }
      refreshPrompt();
    });

    input.addEventListener('keydown', function (ev) {
      if (ev.key === 'ArrowUp') {
        ev.preventDefault();
        if (hpos > 0) input.value = history[--hpos] || '';
      } else if (ev.key === 'ArrowDown') {
        ev.preventDefault();
        if (hpos < history.length - 1) input.value = history[++hpos] || '';
        else { hpos = history.length; input.value = ''; }
      } else if (ev.key === 'Tab') {
        ev.preventDefault();
        var v = input.value.trim();
        if (!v) return;
        var known = ['help', 'ls', 'cat', 'cd', 'pwd', 'id', 'whoami', 'sudo ', 'tail', 'mv', 'chmod', 'find', 'ss', 'ufw', 'echo', 'clear'];
        var hits = known.filter(function (k) { return k.indexOf(v) === 0; });
        if (hits.length === 1) input.value = hits[0];
      }
    });

    document.getElementById('btn-help').addEventListener('click', function () {
      echo('help');
      print(lab.exec('help'));
      input.focus();
    });
    document.getElementById('btn-clear').addEventListener('click', function () {
      screen.textContent = '';
      line('Pantalla limpia. El estado del laboratorio sigue igual.', 'dim');
      input.focus();
    });
    document.getElementById('btn-reset').addEventListener('click', function () {
      lab.reset();
      screen.textContent = '';
      banner();
      refreshPanel();
      refreshPrompt();
      input.focus();
    });
    document.querySelectorAll('[data-user]').forEach(function (b) {
      b.addEventListener('click', function () {
        lab.setUser(b.dataset.user);
        refreshPrompt();
        refreshPanel();
        line('Sesión cambiada a ' + lab.state.user + '.', 'dim');
        input.focus();
      });
    });

    screen.addEventListener('click', function () { input.focus(); });

    function banner() {
      line('Ubuntu 24.04 LTS · vulnserver (simulación) — ' + new Date().toISOString().slice(0, 10), 'dim');
      line('Laboratorio VulnServer v1.0. Esto NO es una VM: es una simulación en JavaScript.', 'warn');
      line('Escribe «help» para ver los comandos. Eres labuser; el propietario es adminlab.', 'dim');
      line('');
    }

    banner();
    refreshPanel();
    refreshPrompt();
    input.focus();

    cronTimer = setInterval(function () {
      var out = lab.cronTick();
      if (out.length) {
        out.forEach(function (l) { line(l.text, l.cls); });
        screen.scrollTop = screen.scrollHeight;
      }
      refreshPanel();
    }, 8000);

    window.addEventListener('pagehide', function () { clearInterval(cronTimer); });
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { makeLab: makeLab };
  } else {
    global.VulnServerDemo = { makeLab: makeLab };
    if (typeof document !== 'undefined') {
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initUI);
      else initUI();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
