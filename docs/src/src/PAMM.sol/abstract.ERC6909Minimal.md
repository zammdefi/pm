# ERC6909Minimal
[Git Source](https://github.com/zammdefi/pm/blob/ce684918478040f32fcb3c1d78c854dba9e39411/src/PAMM.sol)

Minimal ERC6909-style multi-token base for YES/NO shares.


## State Variables
### isOperator

```solidity
mapping(address => mapping(address => bool)) public isOperator
```


### balanceOf

```solidity
mapping(address => mapping(uint256 => uint256)) public balanceOf
```


### allowance

```solidity
mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance
```


## Functions
### transfer


```solidity
function transfer(address receiver, uint256 id, uint256 amount) public returns (bool);
```

### approve


```solidity
function approve(address spender, uint256 id, uint256 amount) public returns (bool);
```

### setOperator


```solidity
function setOperator(address operator, bool approved) public returns (bool);
```

### supportsInterface


```solidity
function supportsInterface(bytes4 interfaceId) public pure returns (bool);
```

### _mint


```solidity
function _mint(address receiver, uint256 id, uint256 amount) internal;
```

### _burn


```solidity
function _burn(address sender, uint256 id, uint256 amount) internal;
```

## Events
### OperatorSet

```solidity
event OperatorSet(address indexed owner, address indexed operator, bool approved);
```

### Approval

```solidity
event Approval(
    address indexed owner, address indexed spender, uint256 indexed id, uint256 amount
);
```

### Transfer

```solidity
event Transfer(
    address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount
);
```

