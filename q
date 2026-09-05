
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


app.use(express.static('public', {
    etag: false,
    lastModified: false,
    maxAge: 0
}));

const sshmikrotik = (command) => {
    const user = 'solisjeffrey7';
    const password = 'XCUTERsj1997';
    const fullCommand = `sshpass -p '${password}' ssh ${user}@10.0.0.1 '${command}'`;

    return new Promise((resolve, reject) => {
        exec(fullCommand, (error, stdout, stderr) => {
    if (error) {
        return reject(error);
    }

    if (stderr && stderr.trim()) {
        console.warn(stderr); // Warning lang, huwag i-reject
    }

    resolve(stdout.trim());
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




app.post('/update-validity', async (req, res) => {

    const { username, password, validity } = req.body;
    const updateexp = "/system script run script3";

    try {

        console.log("Name:", username);
        console.log("Pass:", password);
        console.log("Valid:", validity);

        // Check kung merong user
        const count = await sshmikrotik(
            `:put [:len [/ip hotspot user find where name="${username}"]]`
        );

        // ---------- ADD NEW USER ----------
        if (count.trim() === "0") {

            const expire = addTime(new Date(), validity).trim();

            await sshmikrotik(
                `/ip hotspot user add name="${username}" password="${password}" comment="${expire}" profile="General"`
            );

            await sshmikrotik(updateexp);

            return res.json({
                message: `User added successfully : expired at : ${expire}`
            });

        }

        // ---------- USER EXISTS ----------
        const comment = await sshmikrotik(
            `:put [/ip hotspot user get [find where name="${username}"] comment]`
        );

        console.log("Current Expiration:", comment);

        const newExpire = addTime(comment.trim(), validity);

        await sshmikrotik(
            `/ip hotspot user set [find where name="${username}"] comment="${newExpire}"`
        );

        await sshmikrotik(updateexp);

        return res.json({
            message: `User already exists new expiration date : ${newExpire}`
        });

    } catch (err) {

        console.error(err);

        return res.status(500).json({
            error: err.message
        });

    }

});


let timeoutId;
let countdownInterval;
let countdown;

const resetTimeout = () => {
    if (timeoutId) {
        clearTimeout(timeoutId);
    }
    if (countdownInterval) {
        clearInterval(countdownInterval);
    }

    countdown = 60;

    countdownInterval = setInterval(() => {
        countdown--;

        if (countdown < 0) {
            console.log('done');
            console.log('No traffic detected');
            server.close();
            process.exit(0);
        }
    
    }, 1000);
};


app.get('/quit', (req, res) => {
      console.log('done');
            console.log('user exit');
            server.close();
            process.exit(0);
});
app.get('/qrcode', (req, res) => {
    resetTimeout();
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

