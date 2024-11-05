const express = require('express');
const https = require('https');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');
const app = express();
app.use(express.json());
const port = 3000;

const options = {
    key: fs.readFileSync('./server.key'),
    cert: fs.readFileSync('./server.cert')
};

app.use(express.static('public'));

const sshmikrotik = (command) => {
    const user = 'solisjeffrey7';
    const password = 'XCUTERsj1997';
    const fullCommand = `sshpass -p '${password}' ssh ${user}@10.0.0.1 "${command}"`;

    return new Promise((resolve, reject) => {
        exec(fullCommand, (error, stdout, stderr) => {
            if (stderr) {
                return reject(new Error(`Command execution error: ${stderr}`));
            }
            return resolve(stdout.trim());
        });
    });
};


function escapeString(str) {
    return str.replace(/["'\\]/g, '\\$&');
}

function addTime(t, addt) {
    const rt = getRemainingTime(t);
    const newrt = addTimeToRemainingTime(rt, addt);
    return newrt;
}


function getRemainingTime(targetDate) {
    const now = new Date();
    const target = new Date(targetDate);
    const difference = target - now;

    if (difference < 0) {
        return "0d 0h 0m 0s"; // Return a default format for expired time
    }

    const seconds = Math.floor((difference / 1000) % 60);
    const minutes = Math.floor((difference / 1000 / 60) % 60);
    const hours = Math.floor((difference / 1000 / 60 / 60) % 24);
    const days = Math.floor(difference / (1000 * 60 * 60 * 24));

    return `${days}d ${hours}h ${minutes}m ${seconds}s`;
}


function addTimeToRemainingTime(remainingTime, timeToAdd) {
    const units = {
        d: 24 * 60 * 60 * 1000,
        h: 60 * 60 * 1000,
        m: 60 * 1000,
        s: 1000
    };

    if (!remainingTime || typeof remainingTime !== 'string') {
        console.error("Invalid remaining time:", remainingTime);
        return "Invalid remaining time";
    }

    const timeParts = remainingTime.match(/(\d+)([dhms])/g);
    if (!timeParts) {
        console.error("Unable to parse remaining time:", remainingTime);
        return "Unable to parse remaining time";
    }

    const totalMilliseconds = timeParts.reduce((total, part) => {
        const value = parseInt(part.slice(0, -1), 10);
        const unit = part.slice(-1);
        return total + (value * units[unit]);
    }, 0);

    const now = new Date(totalMilliseconds + Date.now());
    const regex = /(\d+)([dhms])/g;

    let match;
    while ((match = regex.exec(timeToAdd)) !== null) {
        const value = parseInt(match[1], 10);
        const unit = match[2];
        now.setTime(now.getTime() + (value * units[unit]));
    }

    const monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    const month = monthNames[now.getMonth()];
    const day = now.getDate().toString().padStart(2, '0');
    const year = now.getFullYear();

    return `${month}/${day}/${year} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`;
}

app.post('/update-validity', (req, res) => {
    const { username, password, validity } = req.body;
    const commandToExecute = `:put [/ip hotspot user get [find name="${username}"] comment]`;
    const updateexp = '/system script run script3';
    console.log('Name: ' + username);
    console.log('Pass: ' + password);
    console.log('Valid: ' + validity);

    sshmikrotik(commandToExecute)
        .then(result => {
       console.log(result);
            if (!result || result.includes("no such item")) {
                const now = new Date();
                const newu = addTime(now, validity).trim();
                console.log(newu);
                const cmd = `/ip hotspot user add name="${username}" password="${password}" comment="${newu}" profile="General"`;
                console.log(cmd);

                sshmikrotik(escapeString(cmd))
                    .then(addResult => {
                        console.log(`User added successfully expired at: ${addResult}`);
                        res.json({ message: `User added successfully : expired at : ${newu}`});
                        sshmikrotik(escapeString(updateexp));            
        })
                    .catch(addErr => {
                        console.error("Error adding user:", addErr.message);
                        res.status(500).json({ error: "Failed to add user" });
                    });
            } else {


const addtime = addTime(result , validity);
const cmdaddtime = `/ip hotspot user set [find name="${username}"] comment="${addtime}"`
sshmikrotik(escapeString(cmdaddtime))
  .then(result2 => {
                       
 
     console.log("User already exists:", addtime);
     res.json({ message: `User already exists new expiration date : ${addtime}`});
     sshmikrotik(escapeString(updateexp));
 
                    });
            }
        })
        .catch(err => {
            console.error("Error retrieving user:", err.message);
            res.status(500).json({ error: "Failed to retrieve user" });
        });

});



let timeoutId;
let countdownInterval;
let countdown = 20;

const resetTimeout = () => {
    if (timeoutId) {
        clearTimeout(timeoutId);
    }
    if (countdownInterval) {
        clearInterval(countdownInterval);
    }

    countdown = 20;

    countdownInterval = setInterval(() => {
        console.log(`Countdown: ${countdown} seconds remaining`);
        countdown--;

        if (countdown < 0) {
            clearInterval(countdownInterval);
        }
    }, 1000);

    timeoutId = setTimeout(() => {
        console.log('No traffic detected for 20 seconds');
        server.close();
        process.exit(0);
    }, 20000);
};

resetTimeout();


app.get('/qrcode', (req, res) => {
    resetTimeout();
    console.log('RESET TO 20m WiLL auto exit if unuse for 20m');
    res.sendFile(path.join(__dirname, 'public/index.html')); // I-load ang index.html
});

const server = https.createServer(options, app).listen(port, () => {
    console.log(`Server is running at https://localhost:${port}`);

    const command = `am start -a android.intent.action.VIEW -d "https://localhost:${port}/qrcode"`;
    require('child_process').exec(command, (error) => {
        if (error) {
            console.error(`Error opening browser: ${error}`);
        }
    });
});

            
