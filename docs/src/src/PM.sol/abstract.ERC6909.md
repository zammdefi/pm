# ERC6909
[Git Source](https://github.com/zammdefi/pm/blob/006ba95d7cfd5dfbd631c3f6ce5b2bedefc25ed2/src/PM.sol)

**Author:**
Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol)

Minimalist and gas efficient standard ERC6909 implementation.


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
function transfer(address receiver, uint256 id, uint256 amount) public virtual returns (bool);
```

### transferFrom


```solidity
function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    public
    virtual
    returns (bool);
```

### approve


```solidity
function approve(address spender, uint256 id, uint256 amount) public virtual returns (bool);
```

### setOperator


```solidity
function setOperator(address operator, bool approved) public virtual returns (bool);
```

### supportsInterface


```solidity
function supportsInterface(bytes4 interfaceId) public view virtual returns (bool);
```

### _mint


```solidity
function _mint(address receiver, uint256 id, uint256 amount) internal virtual;
```

### _burn


```solidity
function _burn(address sender, uint256 id, uint256 amount) internal virtual;
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

