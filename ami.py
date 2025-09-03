import boto3
import collections
import datetime
import os
import time
 
ec = boto3.client('ec2')
 
def lambda_handler(event, context):
    accountNumber = os.environ['AWS_ACCOUNT_NUMBER']
    retentionDays = int(os.environ['RETENTION_DAYS'])
     
    reservations = ec.describe_instances(Filters=[{'Name': f'tag:{target_tag["Key"]}', 'Values': [target_tag["Value"]]}] ).get('Reservations', [])
    target_tag = {'Key': 'AMI', 'Value': 'test'}
    instances = []
    instance_ids = []
    for reservation in reservations:
        for instance in reservation.get('Instances', []):
            instances.append(instance)
            instance_ids.append(instance['InstanceId'])
 
    instances = sum(
        [
            [i for i in r['Instances']]
            for r in reservations
        ], []
    )
 
    print(f"Found {len(instances)} instances that need backing up")
 
    to_tag = collections.defaultdict(list)
    amiList = []
 
    for instance in instances:
        try:
            retention_days = [
                int(t['Value']) for t in instance['Tags']
                if t['Key'] == 'Retention'
            ][0]
        except IndexError:
            retention_days = retentionDays
 
        create_time = datetime.datetime.now()
        create_fmt = create_time.strftime('%Y-%m-%d-%H-%M-%S')
 
        for tag in instance['Tags']:
            if tag['Key'] == 'Name':
                amiName = tag['Value']
                break
 
        AMIid = ec.create_image(
            InstanceId=instance['InstanceId'],
            Name=f"{amiName} {instance['InstanceId']} {create_fmt}",
            Description=f"Lambda created AMI of instance {instance['InstanceId']} on {create_fmt}",
            NoReboot=True,
            DryRun=False
        )
 
        to_tag[retention_days].append(AMIid['ImageId'])
        amiList.append(AMIid['ImageId'])
        print(f"Retaining AMI {AMIid['ImageId']} of instance {instance['InstanceId']} for {retention_days} days")
 
    for retention_days in to_tag.keys():
        delete_date = datetime.date.today() + datetime.timedelta(days=retention_days)
        delete_fmt = delete_date.strftime('%m-%d-%Y')
        print(f"Will delete {len(to_tag[retention_days])} AMIs on {delete_fmt}")
 
        ec.create_tags(
            Resources=to_tag[retention_days],
            Tags=[
                {'Key': 'DeleteOn', 'Value': delete_fmt},
                {'Key': 'Patching', 'Value': 'True'}
            ]
        )
 
       
       
    snapshotMaster = []
    time.sleep(5)
    print(amiList)
 
    for ami in amiList:
        print(ami)
        snapshots = ec.describe_snapshots(
            DryRun=False,
            OwnerIds=[
                accountNumber
            ],
            Filters=[
                {
                    'Name': 'description',
                    'Values': [
                        f'*{ami}*'
                    ]
                }
            ]
        ).get('Snapshots', [])
 
        print("****************")
 
        for snapshot in snapshots:
            print(snapshot['SnapshotId'])
            ec.create_tags(
                Resources=[snapshot['SnapshotId']],
                Tags=[
                    {'Key': 'DeleteOn', 'Value': delete_fmt},
                    {'Key': 'Patching', 'Value': 'True'}
                ]
            )
 
            if instance_ids:  # Only try to delete if we found instances
                ec.delete_tags(
                Resources=instance_ids,
                Tags=[{'Key': target_tag["Key"]}]
            )
 
