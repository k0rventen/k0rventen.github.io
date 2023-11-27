---
title: "An E-Ink watch"
date: 2023-11-27
description: "A plastic Apple Watch with a Kindle display"
tags: ["embedded","platformio","e-ink"]
---

An 'almost 1 month-battery-life-e-ink-display-watch' that you can build/program.

![watch](/watchy/watchy.jpg)

# what & why

This summer I came across this project: https://sqfmi.com/watchy/. It's a watch with an e-ink display, and a esp32 based platform that you can build upon. And you even have to build it yourself once it arrives in the mail ! And it's "open source hardware and software" ! 

So i ordered one, and played with it when it arrived. The websites claims you can even do OTA update to the watch faces from your phone ! Disclaimer, I never managed to make this feature work. But it's a very cool project nonetheless.

I only need the timekeeping feature of the watch, so the additional capabilites like step counter and weather were a bit useless for my taste, so I decided to dive in the repo. The documentation is very limited, quite sparse, and the only real up-tu-date documentation source is their discord. So I cherry picked what I needed from the OG repo, fork'd it, and made [my own](https://github.com/k0rventen/Watchy) !

With the default code and setup, I could manage at most 6 days before the watch died. The goal was then to increase this as much as possible.

# how

The code is completly rearchitected, and the face isn't decoupled from the logic anymore (as a single watch face was enough).

I then stripped every code that wasn't useful, disabled everything unecessary (eg the step counter). I also removed as much dependencies as possible, and switched the NTP based time sync feature with an API call to the worldtimeapi:

```c
if (settings.timezone == "ip"){
    weatherQueryURL = "http://worldtimeapi.org/api/ip";
}
else{
    weatherQueryURL= "http://worldtimeapi.org/api/timezone/" + settings.timezone;
}
http.begin(weatherQueryURL.c_str());
int httpResponseCode = http.GET();
if (httpResponseCode == 200) {
    String payload             = http.getString();
    JSONVar responseObject     = JSON.parse(payload);
    int epoch = int(responseObject["unixtime"]);
    int dst_offset = int(responseObject["dst_offset"]);
    int tz_offset = int(responseObject["raw_offset"]);
    int local_epoch = epoch + dst_offset + tz_offset;

    tmElements_t tm;
    breakTime((time_t)local_epoch, tm);
    RTC.set(tm);
    ...
```
This is even better than the NTP based one because you can specify `ip` as your timezone, and the API will guess your local zone and respond with the proper local time. 

Finally I added a sleep mode that will put the watch in deepsleep between user-defined hours (eg 23:00 to 07:00). And it will even vibrate (like an Apple Watch) if you've configured a wake up time:

```c
// vibrate if this is alarm time
if (currentTime.Hour == settings.alarmHour && currentTime.Minute == settings.alarmMinute) {
vibMotor(75, 4);
}

// set sleep mode 
if (currentTime.Hour == settings.bedTimeHour && currentTime.Minute == settings.bedTimeMinute) {
showSleep();
}
```


All of these tweaks together bring the battery life to around 25 days, with a time sync every week. Tinkering a bit with some variables could land a whole month, eg by increasing the sleep period, or syncing the time only once when the watch is plugged in.
