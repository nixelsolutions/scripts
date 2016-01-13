#!/usr/bin/env node

var async = require('async');
var AWS = require('aws-sdk');

if ( process.env.AWS_ACCESS_KEY_ID == null) {
  throw new Error('AWS_ACCESS_KEY_ID environment variable not found');
}

if ( process.env.AWS_SECRET_ACCESS_KEY == null) {
  throw new Error('AWS_SECRET_ACCESS_KEY environment variable not found');
}

if (process.env.AWS_REGION == null) {
  throw new Error('AWS_REGION environment variable not found');
}

if (process.env.AWS_ELB_NAMES == null) {
  throw new Error('AWS_ELB_NAMES environment variable not found');
}

var AWS_REGION = process.env.AWS_REGION;
var AWS_ELB_NAMES = process.env.AWS_ELB_NAMES.split(',');

AWS.config.region = AWS_REGION;
var ec2 = new AWS.EC2({apiVersion: '2015-10-01'});
var elb = new AWS.ELB({apiVersion: '2012-06-01'});

async.waterfall([
  // GET Instances from ELB
  function(callback) {
    elb.describeLoadBalancers({LoadBalancerNames: AWS_ELB_NAMES}, function(err, data) {
      if (err) throw new Error('Error while getting information from ELBs: ' +AWS_ELB_NAMES+ '\n' +err.stack);
//      console.log("Got this info from ELBS " +AWS_ELB_NAMES+ " : " +JSON.stringify(data));
      callback(null, data);
    });
  },
  // Fill data to elbInfo
  function(elbData, callback) {
    var elbInfo = [];
    async.eachSeries(elbData.LoadBalancerDescriptions, function(loadBalancer, callback) {
      lb = loadBalancer;
      lb.ParsedInstances = [];
      async.each(lb.Instances, function(instance, callback) {
        ec2.describeInstances({InstanceIds: [instance.InstanceId]}, function(err, data) {
          if (err) throw new Error('Error while getting information from Instace with ID: ' +instance.InstanceId+ '\n' +err.stack);
//          console.log("Got this info from Instance with ID " +instance.InstanceId+ " : " +JSON.stringify(data));
//          console.log("Pushing instance info on LB " +lb.LoadBalancerName);
          lb.ParsedInstances.push(data.Reservations[0].Instances[0])
          callback();
        });
      }, function (err) {
        if (err) throw new Error(err);
        callback();
      });
//        console.log("Pushing LB " +lb.LoadBalancerName);
        elbInfo.push(lb);
    }, function (err) {
      if (err) throw new Error(err);
      callback(null, elbInfo);
    });
  }
],
function (err, result) {
  if (err) throw new Error(err);
  console.log('elbInfo = ' +JSON.stringify(result));
});
