#!/bin/bash
set -e

echo "Update sistem..."
apt update && apt upgrade -y

echo "Install Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs sqlite3

echo "Buat direktori aplikasi..."
mkdir -p /opt/chatgpt-mem
cd /opt/chatgpt-mem

echo "Buat file package.json..."
cat > package.json <<EOF
{
  "name": "chatgpt-mem",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "sqlite3": "^5.1.6",
    "body-parser": "^1.20.2",
    "cors": "^2.8.5"
  }
}
EOF

echo "Install dependencies..."
npm install

echo "Buat file server.js..."
cat > server.js <<'EOL'
const express = require('express');
const sqlite3 = require('sqlite3');
const bodyParser = require('body-parser');
const cors = require('cors');
const fs = require('fs');
const app = express();
const PORT = 3000;

app.use(cors());
app.use(bodyParser.json());

const db = new sqlite3.Database('./chat.db');
db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS chats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user TEXT,
    message TEXT,
    response TEXT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);
});

function generateResponse(message, history) {
  let reply = "Kamu berkata: " + message + ". Ini balasan sederhana dari server.";
  if(message.toLowerCase().includes('kode')) {
    reply += "\n\n```javascript\nconsole.log('Ini contoh kode JavaScript');\n```";
  }
  return reply;
}

app.post('/chat', (req, res) => {
  const user = req.body.user || "anonymous";
  const message = req.body.message || "";

  db.all(`SELECT message, response FROM chats WHERE user = ? ORDER BY id DESC LIMIT 5`, [user], (err, rows) => {
    if(err) return res.status(500).json({error: err.message});

    let history = rows.reverse().map(r => `User: ${r.message}\nBot: ${r.response}`).join('\n');

    const response = generateResponse(message, history);

    db.run(`INSERT INTO chats(user, message, response) VALUES(?,?,?)`, [user, message, response]);

    res.json({response});
  });
});

app.get('/export/:user', (req, res) => {
  const user = req.params.user;

  db.all(`SELECT message, response, timestamp FROM chats WHERE user = ? ORDER BY id`, [user], (err, rows) => {
    if(err) return res.status(500).send("Error export chat");

    let content = `Chat history user: ${user}\n\n`;
    rows.forEach(r => {
      content += `[${r.timestamp}]\nUser: ${r.message}\nBot: ${r.response}\n\n`;
    });

    const filename = `/tmp/chat_${user}.txt`;
    fs.writeFileSync(filename, content);

    res.download(filename, `chat_${user}.txt`, err => {
      fs.unlinkSync(filename);
    });
  });
});

app.get('/', (req, res) => {
  res.send(`
  <!DOCTYPE html>
  <html>
  <head>
    <title>Chat GPT Mini</title>
    <style>
      body { font-family: Arial; margin: 2rem; }
      #chat { border: 1px solid #ccc; padding: 1rem; height: 300px; overflow-y: scroll; }
      #input { width: 80%; }
      button { width: 18%; }
      pre { background: #eee; padding: 0.5rem; }
    </style>
  </head>
  <body>
    <h2>Chat GPT Mini dengan Memori</h2>
    <input type="text" id="user" placeholder="Username" value="user1" />
    <div id="chat"></div>
    <input type="text" id="input" placeholder="Ketik pesan..." autocomplete="off" />
    <button onclick="sendMessage()">Kirim</button>
    <button onclick="exportChat()">Export Chat</button>

    <script>
      const chatDiv = document.getElementById('chat');
      const input = document.getElementById('input');
      const userInput = document.getElementById('user');

      function appendMessage(sender, text) {
        if(text.match(/```([\\s\\S]*?)```/gm)){
          text = text.replace(/```([\\s\\S]*?)```/gm, (match, p1) => {
            return '<pre>' + p1 + '</pre>';
          });
        }
        const div = document.createElement('div');
        div.innerHTML = '<b>' + sender + ':</b> ' + text;
        chatDiv.appendChild(div);
        chatDiv.scrollTop = chatDiv.scrollHeight;
      }

      async function sendMessage(){
        const user = userInput.value.trim();
        const message = input.value.trim();
        if(!user || !message) return alert("Isi username dan pesan!");

        appendMessage('You', message);

        const res = await fetch('/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ user, message })
        });
        const data = await res.json();
        appendMessage('Bot', data.response);
        input.value = '';
      }

      function exportChat(){
        const user = userInput.value.trim();
        if(!user) return alert("Isi username untuk export!");

        window.open('/export/' + user, '_blank');
      }
    </script>
  </body>
  </html>
  `);
});

app.listen(PORT, () => {
  console.log(`Server berjalan di http://localhost:${PORT}`);
});
EOL

echo "Buat service systemd..."
cat > /etc/systemd/system/chatgpt-mem.service <<EOF
[Unit]
Description=ChatGPT Mini dengan Memori
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/chatgpt-mem/server.js
Restart=always
User=nobody
Environment=NODE_ENV=production
WorkingDirectory=/opt/chatgpt-mem

[Install]
WantedBy=multi-user.target
EOF

echo "Reload systemd dan aktifkan service..."
systemctl daemon-reload
systemctl enable chatgpt-mem.service
systemctl start chatgpt-mem.service

# Ambil IP publik otomatis
PUBLIC_IP=$(curl -s https://api.ipify.org || echo "IP_Tidak_Diketahui")

echo "Selesai. Aplikasi bisa diakses di http://$PUBLIC_IP:3000"
