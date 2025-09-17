"""A Pulumi program to create 3 AWS EC2 instances."""

import pulumi
import pulumi_aws as aws

# Create a new VPC explicitly
vpc = aws.ec2.Vpc("my-vpc",
    cidr_block="10.0.0.0/16",
    tags={
        "Name": "my-pulumi-vpc",
    }
)

#  Create a public subnet within the new VPC
public_subnet = aws.ec2.Subnet("my-public-subnet",
    vpc_id=vpc.id,
    cidr_block="10.0.1.0/24",
    map_public_ip_on_launch=True,
    availability_zone="us-east-1a",
    tags={
        "Name": "my-pulumi-public-subnet",
    }
)

# Create a security group to allow Kubernetes and SSH traffic.
security_group = aws.ec2.SecurityGroup(
    "web-sg",
    vpc_id=vpc.id,
    ingress=[
        # SSH access for management.
        aws.ec2.SecurityGroupIngressArgs(
            protocol="tcp",
            from_port=22,
            to_port=22,
            cidr_blocks=["0.0.0.0/0"],
            description="Allow SSH access",
        ),
        # Kubernetes API Server access.
        aws.ec2.SecurityGroupIngressArgs(
            protocol="tcp",
            from_port=6443,
            to_port=6443,
            cidr_blocks=["0.0.0.0/0"],
            description="Kubernetes API Server",
        ),
        # Etcd server access.
        aws.ec2.SecurityGroupIngressArgs(
            protocol="tcp",
            from_port=2379,
            to_port=2380,
            cidr_blocks=["0.0.0.0/0"],
            description="etcd Server Client API",
        ),
        # Kubelet API.
        aws.ec2.SecurityGroupIngressArgs(
            protocol="tcp",
            from_port=10250,
            to_port=10250,
            cidr_blocks=["0.0.0.0/0"],
            description="Kubelet API",
        ),
        # Kube-scheduler.
        aws.ec2.SecurityGroupIngressArgs(
            protocol="tcp",
            from_port=10259,
            to_port=10259,
            cidr_blocks=["0.0.0.0/0"],
            description="Kube Scheduler",
        ),
        # Kube-controller-manager.
        aws.ec2.SecurityGroupIngressArgs(
            protocol="tcp",
            from_port=10257,
            to_port=10257,
            cidr_blocks=["0.0.0.0/0"],
            description="Kube Controller Manager",
        ),
    ],
    egress=[
        # Allow all outbound traffic.
        aws.ec2.SecurityGroupEgressArgs(
            protocol="-1",
            from_port=0,
            to_port=0,
            cidr_blocks=["0.0.0.0/0"],
        )
    ],
    tags={
        "Name": "web-server-sg",
    },
)

# Get the latest Amazon Linux 2 AMI
ami = aws.ec2.get_ami(
    most_recent=True,
    owners=["amazon"],
    filters=[
        aws.ec2.GetAmiFilterArgs(name="name", values=["amzn2-ami-hvm-*-x86_64-gp2"]),
    ],
)

# Get the SSH key pair name from Pulumi configuration.
config = pulumi.Config()
key_pair_name = config.require("ssh_key_name")

# Create three EC2 instances.
instance_names = ["control-plane-1", "control-plane-2", "worker-1"]
instances = []
for i, name in enumerate(instance_names):
    instance = aws.ec2.Instance(
        f"instance-{i}",
        ami=ami.id,
        instance_type="t3.small",  
        vpc_security_group_ids=[security_group.id],
        key_name=key_pair_name,
        subnet_id=public_subnet.id, 
        tags={
            "Name": name,
        },
    )
    instances.append(instance)

# Export the public IPs and hostnames of the instances.
pulumi.export("instance_ips", [inst.public_ip for inst in instances])
pulumi.export("instance_dns", [inst.public_dns for inst in instances])