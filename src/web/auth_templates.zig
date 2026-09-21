pub const password_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow"><title>Change password - Verso</title>
    \\<link rel="stylesheet" href="/admin/theme.css"><link rel="stylesheet" href="/admin/admin.css"></head>
    \\<body class="standalone-page"><main class="standalone-shell"><article class="standalone-card">
    \\<header class="standalone-header"><a class="standalone-brand" href="/" aria-label="Verso home"><span class="standalone-brand-mark">V</span> Verso</a>
    \\<p class="eyebrow">Account settings</p><h1>Change password</h1><p>Keep your editorial workspace protected with a new password.</p></header>
    \\<form class="standalone-form" method="post" action="/admin/password">
    \\<input type="hidden" name="csrf_token" value="{s}">
    \\<label>Current password <input type="password" name="current_password" autocomplete="current-password" required></label>
    \\<label>New password <input type="password" name="new_password" autocomplete="new-password" required></label>
    \\<div class="standalone-actions"><button class="theme-button theme-button-primary" type="submit">Change password</button><a class="theme-button theme-button-quiet" href="/admin/editor">Cancel</a></div></form>
    \\<footer class="standalone-footer"><span>Your publication stays in your hands.</span><a href="/admin/authors">Manage authors</a></footer>
    \\</article></main></body></html>
;

pub const recovery_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow"><title>Password recovery - Verso</title>
    \\<link rel="stylesheet" href="/admin/theme.css"><link rel="stylesheet" href="/admin/admin.css"></head>
    \\<body class="standalone-page"><main class="standalone-shell"><article class="standalone-card">
    \\<header class="standalone-header"><a class="standalone-brand" href="/" aria-label="Verso home"><span class="standalone-brand-mark">V</span> Verso</a>
    \\<p class="eyebrow">Account access</p><h1>Password recovery</h1><p>Enter your login and, if the account exists, recovery instructions will be sent.</p></header>
    \\<form class="standalone-form" method="post" action="/admin/recover">
    \\<label>Login <input name="login" autocomplete="username" required></label>
    \\<div class="standalone-actions"><button class="theme-button theme-button-primary" type="submit">Request recovery</button><a class="theme-button theme-button-quiet" href="/admin/login">Back to sign in</a></div></form>
    \\<footer class="standalone-footer"><span>Need another route in?</span><a href="/admin/recover/complete">Use a recovery token</a></footer>
    \\</article></main></body></html>
;

pub const recovery_complete_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow"><title>Set a new password - Verso</title>
    \\<link rel="stylesheet" href="/admin/theme.css"><link rel="stylesheet" href="/admin/admin.css"></head>
    \\<body class="standalone-page"><main class="standalone-shell"><article class="standalone-card">
    \\<header class="standalone-header"><a class="standalone-brand" href="/" aria-label="Verso home"><span class="standalone-brand-mark">V</span> Verso</a>
    \\<p class="eyebrow">Account access</p><h1>Set a new password</h1><p>Use the recovery token you received to choose a new password.</p></header>
    \\<form class="standalone-form" method="post" action="/admin/recover/complete">
    \\<label>Recovery token <input name="token" autocomplete="one-time-code" required></label>
    \\<label>New password <input type="password" name="new_password" autocomplete="new-password" required></label>
    \\<div class="standalone-actions"><button class="theme-button theme-button-primary" type="submit">Set password</button><a class="theme-button theme-button-quiet" href="/admin/login">Back to sign in</a></div></form>
    \\<footer class="standalone-footer"><span>Recovery tokens are single-use.</span><a href="/admin/recover">Request another</a></footer>
    \\</article></main></body></html>
;
