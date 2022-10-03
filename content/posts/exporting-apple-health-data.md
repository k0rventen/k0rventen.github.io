---
title: "Exporting Apple Health Data"
date: 2022-08-23T20:44:24+02:00
draft: false
description: "Graph your health using grafana"
tags : ["apple","influx","python","grafana"]
---

_Example of metrics exported from Apple Health in Grafana:_
![](https://github.com/k0rventen/apple-health-grafana/raw/main/example.png)


__If you want to test the tool, check out the [Github repo here](https://github.com/k0rventen/apple-health-grafana)__

## what & why

Having a health tracker such as an apple watch is great, but the default views in the Health app on the iPhone can be too simplistic. We can't correlate between metrics, define a specific time range, etc.. 

But it's possible to export all of the collected health data in an archive. The goal then is to parse this archive and import it in a more analysis friendly tool. I'm most familiar with the InfluxDB+Grafana stack, so that's what I'll be using, but the parsing tool should provide a groundwork for parsing the exported data, and could be adapted to import to other tools.



# how


## Architecture

The tool is a 3 components docker-compose stack:
- a parsing container that will ingest our exported health data,
- influxDB for storing the data
- grafana to visualize

## Export format

From support.apple.com:
```
Share your health and fitness data in XML format

You can export all of your health and fitness data from Health in XML format, which is a common format for sharing data between apps.

    Tap your profile picture or initials at the top right.

    If you don’t see your profile picture or initials, tap Summary or Browse at the bottom of the screen, then scroll to the top of the screen.

    Tap Export all health data, then choose a method for sharing your data.
```

This will create a .zip file that can be shared from the iPhone.

Once you've copied/share the file to your computer, unzip it. You should have a `export.xml` file in there.
This file contains all the health records recorded by the Health app.

The format is as follow:
k
```xml
<Record type="HKQuantityTypeIdentifierHeartRate" sourceName="apple-watch" sourceVersion="8.7" device="&lt;&lt;HKDevice: 0x2803d9810&gt;, name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch3,4, software:8.7&gt;" unit="count/min" creationDate="2022-07-26 17:28:52 +0200" startDate="2022-07-26 17:22:58 +0200" endDate="2022-07-26 17:22:58 +0200" value="73">
  <MetadataEntry key="HKMetadataKeyHeartRateMotionContext" value="0"/>
 </Record>
```

Each record contains at least a `type`, which is the category of the metric, `timestamps`, a `value` and a `unit`. We also have access to the tracker that recorded the metric.

The ingester iterates through all the records, parses the important fields, then yields a dict that can be used as a measurement for influx.


## Tips on analyzing the data

Some metrics can be displayed __as is__, but others might need tweaking in the influx request:
- adjusting the time interval to 1d.
- using __sum()__ instead of __mean()__ to aggregate the metrics for a given interval.
