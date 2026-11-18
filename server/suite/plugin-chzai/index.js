// Chausima Suite: adds "AI writing helper" to the user menu. Only serves its own client file; no server logic.
const Path = require('node:path');
const Express = require('express');
module.exports = {
    name: "CHZAI",
    modules: {
        httpEndpoints: [{ type: 'http', f: (Env, app) => { app.use('/chzai', Express.static(Path.join(__dirname, 'client'))); } }]
    }
};
